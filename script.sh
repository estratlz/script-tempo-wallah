#!/usr/bin/env bash
# Meowcord Debian 12 - installation personnalisee
# Source officielle : https://github.com/meowcorded/meowcord
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo 'Lancez ce script avec : sudo bash install-meowcord-custom.sh' >&2
  exit 1
fi
if ! command -v apt-get >/dev/null || ! grep -q 'VERSION_ID="12"' /etc/os-release; then
  echo 'Ce script est prevu pour Debian 12.' >&2
  exit 1
fi
if [[ -e /opt/meowcord ]]; then
  echo '/opt/meowcord existe deja : installation annulee pour proteger les donnees.' >&2
  exit 1
fi

read -r -p 'Domaine [uhqchatting.eu.cc] : ' DOMAIN </dev/tty
DOMAIN=${DOMAIN:-uhqchatting.eu.cc}
read -r -p 'IP publique IPv4 [82.26.80.178] : ' PUBLIC_IP </dev/tty
PUBLIC_IP=${PUBLIC_IP:-82.26.80.178}
read -r -p "Nom de l'instance [Meowcord] : " INSTANCE_NAME </dev/tty
INSTANCE_NAME=${INSTANCE_NAME:-Meowcord}
read -r -p 'Importer des decorations Discord depuis une archive communautaire ancienne ? [O/n] : ' GET_DECORATIONS </dev/tty
GET_DECORATIONS=${GET_DECORATIONS:-O}

export DOMAIN PUBLIC_IP INSTANCE_NAME
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ca-certificates curl gnupg git openssl python3

python3 - <<'PY'
import ipaddress, os, re
name = os.environ['DOMAIN']
if not (len(name) <= 253 and re.fullmatch(r'(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}', name)):
    raise SystemExit('Domaine invalide.')
ipaddress.IPv4Address(os.environ['PUBLIC_IP'])
if '\n' in os.environ['INSTANCE_NAME'] or '\r' in os.environ['INSTANCE_NAME']:
    raise SystemExit('Nom d instance invalide.')
PY


if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  echo 'Installation de Docker Engine / Compose depuis le depot officiel Docker...'
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

git clone --depth 1 https://github.com/meowcorded/meowcord.git /opt/meowcord
cd /opt/meowcord
cp .env.example .env
export DB_PASSWORD TURN_SECRET VOLUME_PREFIX
DB_PASSWORD=$(openssl rand -hex 24)
TURN_SECRET=$(openssl rand -hex 32)
VOLUME_PREFIX="meowcustom_$(date +%s)"
python3 - <<'PY'
from pathlib import Path
import os
p = Path('.env')
s = p.read_text()
updates = {
    'DOMAIN': os.environ['DOMAIN'],
    'WRTC_PUBLIC_IP': os.environ['PUBLIC_IP'],
    'POSTGRES_PASSWORD': os.environ['DB_PASSWORD'],
    'TURN_SECRET': os.environ['TURN_SECRET'],
    'MEOWCORD_VOLUME_PREFIX': os.environ['VOLUME_PREFIX'],
    'INSTANCE_NAME': os.environ['INSTANCE_NAME'],
    'COMPOSE_PROFILES': 'caddy',
}
for key, value in updates.items():
    lines = s.splitlines()
    found = False
    for idx, line in enumerate(lines):
        if line.startswith(key+'=') or line.startswith('#'+key+'='):
            lines[idx] = key+'='+value
            found = True
            break
    if not found:
        lines.append(key+'='+value)
    s = '\n'.join(lines)+'\n'
p.write_text(s)
PY
chmod 600 .env

# IMPORTANT : le code Meowcord est en alpha. Les remplacements sont controles
# et on refuse d'appliquer une modification si l'upstream a change.
python3 - <<'PY'
from pathlib import Path
import re, json, time, shutil
changes = {}

def get(name):
    return changes.get(name, Path(name).read_text())

def put(name, text):
    changes[name] = text

def replace_once(name, old, new, label):
    s = get(name)
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'Patch incompatible ({label}) : {n} correspondance(s). Rien ne sera modifie.')
    put(name, s.replace(old, new, 1))

def regex_once(name, pattern, repl, label, flags=0):
    s, count = re.subn(pattern, repl, get(name), count=1, flags=flags)
    if count != 1:
        raise SystemExit(f'Patch incompatible ({label}) : {count} correspondance(s). Rien ne sera modifie.')
    put(name, s)

# 1) 0 boost pour les nouveaux serveurs ; les boosts existants ne sont pas modifies.
guild = 'src/database/entities/Guild.ts'
replace_once(guild, 'AfterLoad, ', '', 'deco AfterLoad')
replace_once(guild, 'export const GuildBoostCount = 33;', 'export const GuildBoostCount = 0;', 'valeur boosts')
regex_once(guild, r'@AfterLoad\(\)\s*\n\s*applyBoostPerks\(\)\s*\{[\s\S]*?\n\s*\}\s*(?=static async countOnlineMembersIn)', '', 'suppression perks imposes')
replace_once(guild, 'premium_subscription_count: GuildBoostCount,', 'premium_subscription_count: 0,', 'boost creation')
replace_once(guild, 'premium_tier: GuildPremiumTier.TIER_3,', 'premium_tier: GuildPremiumTier.NONE,', 'tier creation')
replace_once(guild,
    'features: [...new Set([...Config.get().guild.defaultFeatures, ...GuildBoostFeatures])],',
    'features: [...Config.get().guild.defaultFeatures],', 'features creation')

# 2) Les operateurs/staff MANAGE_GUILDS peuvent fixer le nombre de boosts depuis /admin.
schema = 'src/schemas/api/spacebar/Admin.ts'
replace_once(schema,
  'premium_tier?: number;',
  'premium_tier?: number;\n/** @minimum 0\n * @maximum 10000 */\npremium_subscription_count?: number;',
  'schema admin')

adminroute = 'src/api/routes/admin/guilds/#guild_id/index.ts'
replace_once(adminroute,
    'import { Channel, FederatedObject, Guild, Member, User } from "@spacebar/database";',
    'import { Channel, FederatedObject, Guild, Member, User } from "@spacebar/database";\nimport { GuildBoostFeatures } from "@spacebar/database/entities/Guild";',
    'import boosts admin')
replace_once(adminroute,
    'premium_tier: true,',
    'premium_tier: true,\npremium_subscription_count: true,', 'selection nombre boosts')
replace_once(adminroute,
    'premium_tier: guild.premium_tier ?? 0,',
    'premium_tier: guild.premium_tier ?? 0,\npremium_subscription_count: guild.premium_subscription_count ?? 0,', 'retour boosts admin')
replace_once(adminroute,
    'if (body.features !== undefined) guild.features = [...new Set(body.features.map((f) => f.trim().toUpperCase()).filter(Boolean))];',
    '''if (body.features !== undefined) guild.features = [...new Set(body.features.map((f) => f.trim().toUpperCase()).filter(Boolean))];
if (body.premium_subscription_count !== undefined) {
  const count = body.premium_subscription_count;
  if (!Number.isInteger(count) || count < 0 || count > 10000) throw new HTTPError("Boost count must be between 0 and 10000", 400);
  guild.premium_subscription_count = count;
  guild.premium_tier = count >= 14 ? 3 : count >= 7 ? 2 : count >= 2 ? 1 : 0;
  guild.features = [...new Set([
    ...(guild.features ?? []).filter((feature) => !GuildBoostFeatures.includes(feature)),
    ...(count >= 14 ? GuildBoostFeatures : []),
  ])];
}''', 'enregistrer nombre boosts')

admindashboard = 'assets/public/admin/admin.js'
replace_once(admindashboard,
    '                    <label\n                        >Inactive voice timeout<select name="afk_timeout">',
    '''                    <label>Boost count (staff)<input name="premium_subscription_count" type="number" min="0" max="10000" step="1" required value="${g.premium_subscription_count ?? 0}" /></label>
                    <label
                        >Inactive voice timeout<select name="afk_timeout">''', 'champ boosts panel')
replace_once(admindashboard,
    '    const owner = form.owner_id.value.trim();',
    '''    patch.premium_subscription_count = Number(form.elements.premium_subscription_count.value);
    const owner = form.owner_id.value.trim();''', 'soumettre boosts panel')

# JSON schema deja embarque : son edition est necessaire pour accepter le nouveau champ.
schemapath = 'assets/schemas.json'
rawschemas = json.loads(get(schemapath))
adminschema = rawschemas.get('AdminGuildUpdateSchema')
if not isinstance(adminschema, dict) or not isinstance(adminschema.get('properties'), dict):
    raise SystemExit('Le schema AdminGuildUpdateSchema est introuvable. Rien ne sera modifie.')
adminschema['properties']['premium_subscription_count'] = {'type':'integer', 'minimum':0, 'maximum':10000}
put(schemapath, json.dumps(rawschemas, ensure_ascii=False, indent=2)+'\n')

# 3) Pride : masquer le selecteur client, refuser de nouvelles selections API,
# laisser la base historique intacte, masquer les badges existants dans les profils.
plugin = 'client/plugins/fosscordPride/index.tsx'
if 'name: "FosscordPride"' not in get(plugin):
    raise SystemExit('Le plugin Pride a change. Rien ne sera modifie.')
put(plugin, '''import definePlugin from "@utils/types";
import { FosscordAuthor } from "../fosscordCore/shared";
export default definePlugin({
  name: "FosscordPride",
  description: "Disabled by the local instance operator",
  authors: [FosscordAuthor],
  required: true,
  patches: [],
});
''')

user = 'src/database/entities/User.ts'
replace_once(user,
    'pride_badges: [...new Set(pride_badges ?? [])],',
    'pride_badges: [],', 'ne pas assigner badges a inscription')

badgeutils = 'src/api/util/utility/prideBadges.ts'
s = get(badgeutils)
marker = 'export const prideBadges = (selected: readonly string[] | null | undefined) =>'
if s.count(marker) != 1:
    raise SystemExit('Rendu Pride introuvable. Rien ne sera modifie.')
put(badgeutils, s[:s.index(marker)] + '''export const prideBadges = (_selected: readonly string[] | null | undefined): { id: string; description: string; icon: string }[] => [];
''')

public = 'src/api/routes/auth/pride-badges.ts'
replace_once(public, 'res.set("Cache-Control", "public, max-age=300").json(publicPrideBadges());',
             'res.set("Cache-Control", "no-store").json({ max_selections: 0, badges: [] });', 'catalogue public vide')

for filename in ('src/api/routes/users/@me/pride-badges.ts', 'src/api/routes/admin/users/#user_id/pride-badges.ts'):
    replace_once(filename,
        'const { flags } = req.body as PrideBadgesSchema;',
        '''const { flags } = req.body as PrideBadgesSchema;
if (Array.isArray(flags) && flags.length > 0) {
  res.status(403).json({ message: "Pride badge selection is disabled on this instance" });
  return;
}''', 'bloquer ajout '+filename)

# Apply all patches only if every signature above is verified.
stamp = time.strftime('%Y%m%d-%H%M%S')
for name, value in changes.items():
    file = Path(name)
    backup = file.with_name(file.name+'.before-custom-'+stamp)
    shutil.copy2(file, backup)
    file.write_text(value)
print(f'Patches appliques : {len(changes)} fichiers (sauvegardes .before-custom-{stamp})')
PY

# Source communautaire independante de Discord; les donnees sont archivees (anciennes).
if [[ "$GET_DECORATIONS" =~ ^([OoYy]|oui|yes)$ ]]; then
  echo 'Import optionnel du catalogue Discord archive (non officiel)...'
  TEMP_CAT=$(mktemp)
  TEMP_FX=$(mktemp)
  if curl --fail --location --silent --show-error --retry 2 \
    'https://raw.githubusercontent.com/Infinitay/discord-collectibles-archive/main/discord-data/raw/collectibles-categories.json' -o "$TEMP_CAT" && \
    curl --fail --location --silent --show-error --retry 2 \
    'https://raw.githubusercontent.com/Infinitay/discord-collectibles-archive/main/discord-data/raw/user-profile-effects.json' -o "$TEMP_FX" && \
    python3 - "$TEMP_CAT" "$TEMP_FX" <<'PY'
import json,sys
from pathlib import Path
categories = json.loads(Path(sys.argv[1]).read_text())
fx = json.loads(Path(sys.argv[2]).read_text())
fx = fx.get('profile_effect_configs') if isinstance(fx,dict) else fx
if not isinstance(categories,list) or not categories or not isinstance(fx,list) or not fx:
    raise SystemExit('Format du catalogue Discord invalide')
if not all(isinstance(c,dict) and 'sku_id' in c and 'products' in c for c in categories):
    raise SystemExit('Categories invalides')
if not all(isinstance(c,dict) and 'sku_id' in c for c in fx):
    raise SystemExit('Effets invalides')
Path('assets/collectibles.json').write_text(json.dumps(categories,ensure_ascii=False))
Path('assets/profile-effects.json').write_text(json.dumps(fx,ensure_ascii=False))
print(f'Decorations chargees : {len(categories)} categories et {len(fx)} effets')
PY
  then
    echo 'Archive chargee (son catalogue ne represente pas necessairement le Shop actuel).'
  else
    echo 'Avertissement : import non disponible. Le Shop conserve ses contenus natifs.' >&2
  fi
  rm -f "$TEMP_CAT" "$TEMP_FX"
fi

echo 'Verification et lancement de Meowcord...'
docker compose config -q
docker compose up -d --build
docker compose ps -a
printf '\nInstance configuree : https://%s/register\n' "$DOMAIN"
printf 'Admin (apres attribution operator) : https://%s/admin\n' "$DOMAIN"
printf 'IMPORTANT : ouvrir les ports 80/443 TCP, 443 UDP, 50000 UDP, 3478 TCP/UDP et 49160-49200 UDP.\n'
printf 'La creation initiale du compte se fait depuis le navigateur.\n'
printf 'Pour attribuer operator : cd /opt/meowcord && docker compose exec server bun scripts/ops/operator.mjs grant ID_UTILISATEUR\n'
