#!/usr/bin/env bash
# ==============================================================================
# keycloak_migrate.sh
# Export e import completo de configuracion Keycloak via Admin REST API.
# Requiere: curl, jq
# ==============================================================================
set -uo pipefail

# ---- Variables globales -------------------------------------------------------
KC_URL=""; KC_USER=""; KC_PASS=""
OUTPUT_FILE=""; INPUT_FILE=""
FORCE=false; INCLUDE_MASTER=false
DEFAULT_PASSWORD=""; NO_SSL=false
TOKEN=""; GROUP_MAP="{}"

# ---- Colores ------------------------------------------------------------------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${G}[OK]${NC}  $*"; }
err()  { echo -e "${R}[ERROR]${NC} $*" >&2; }
warn() { echo -e "${Y}[WARN]${NC} $*"; }
info() { echo "    [*] $*"; }

# ---- Dependencias -------------------------------------------------------------
check_deps() {
    for dep in curl jq; do
        command -v "$dep" &>/dev/null || { err "Falta dependencia: $dep  ->  brew install $dep"; exit 1; }
    done
}

# ==============================================================================
# HTTP helpers
# ==============================================================================
_curl() {
    local ssl_opt=()
    [[ "$NO_SSL" == true ]] && ssl_opt=(-k)
    curl -s "${ssl_opt[@]}" "$@"
}

authenticate() {
    TOKEN=$(_curl -f -X POST \
        "${KC_URL}/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=admin-cli&username=${KC_USER}&password=${KC_PASS}" \
        | jq -r '.access_token')
    [[ -z "$TOKEN" || "$TOKEN" == "null" ]] && { err "Autenticacion fallida"; exit 1; }
}

kc_get() {
    _curl -f -H "Authorization: Bearer ${TOKEN}" "${KC_URL}$1"
}

# Retorna "STATUS LOCATION" (para capturar ID de recursos creados)
kc_post() {
    local tmpf; tmpf=$(mktemp)
    local status
    status=$(_curl -o /dev/null -w "%{http_code}" \
        -D "$tmpf" -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$2" "${KC_URL}$1")
    local loc
    loc=$(grep -i "^location:" "$tmpf" | tr -d '\r' | awk '{print $2}' || true)
    rm -f "$tmpf"
    echo "${status} ${loc}"
}

# POST que devuelve el body de la respuesta (ej: partial-export)
kc_post_body() {
    _curl -f -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${2:-{\}}" "${KC_URL}$1"
}

# Retorna HTTP status code
kc_put() {
    _curl -o /dev/null -w "%{http_code}" -X PUT \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$2" "${KC_URL}$1"
}

# Retorna HTTP status code
kc_delete() {
    _curl -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: Bearer ${TOKEN}" "${KC_URL}$1"
}

# ==============================================================================
# Helpers export
# ==============================================================================
get_all_users() {
    local realm="$1" all="[]" first=0 page=100
    while true; do
        local batch count
        batch=$(kc_get "/admin/realms/${realm}/users?first=${first}&max=${page}&briefRepresentation=false" 2>/dev/null || echo "[]")
        count=$(echo "$batch" | jq 'length')
        all=$(jq -n --argjson a "$all" --argjson b "$batch" '$a + $b')
        [[ "$count" -lt "$page" ]] && break
        first=$((first + page))
    done
    echo "$all"
}

# Construye mapa { "/Grupo": "id", "/Grupo/Sub": "id" } de forma recursiva
build_group_map() {
    local realm="$1"
    local groups
    groups=$(kc_get "/admin/realms/${realm}/groups?max=1000&briefRepresentation=false" 2>/dev/null || echo "[]")
    GROUP_MAP=$(echo "$groups" | jq '
        def flatten(prefix):
            .[] | . as $g |
            {key: "\(prefix)/\($g.name)", value: $g.id},
            (if ($g.subGroups | length) > 0 then
                $g.subGroups | flatten("\(prefix)/\($g.name)")
            else empty end);
        [flatten("")] | from_entries // {}
    ')
}

# ==============================================================================
# EXPORT
# ==============================================================================
do_export() {
    echo "[*] Conectando a Keycloak: ${KC_URL}"
    authenticate
    ok "Autenticacion exitosa"; echo ""

    info "Obteniendo lista de realms..."
    local realms_raw
    realms_raw=$(kc_get "/admin/realms")
    local realms_json="[]"

    while IFS= read -r realm_info; do
        local rname
        rname=$(echo "$realm_info" | jq -r '.realm')
        [[ "$INCLUDE_MASTER" == false && "$rname" == "master" ]] && {
            echo "    [~] Saltando realm 'master'"; continue
        }

        echo ""; echo "[*] Exportando realm: '${rname}'"

        # 1. Configuracion base via partial-export
        info "Configuracion base (partial-export)..."
        local realm_data
        realm_data=$(kc_post_body \
            "/admin/realms/${rname}/partial-export?exportClients=true&exportGroupsAndRoles=true" \
            "{}") || { warn "partial-export fallo para '${rname}'"; continue; }

        # 2. Usuarios (paginados)
        info "Exportando usuarios..."
        local all_users users_count
        all_users=$(get_all_users "$rname")
        users_count=$(echo "$all_users" | jq 'length')
        echo "        Encontrados: ${users_count} usuarios"

        local users_full="[]"
        while IFS= read -r user_json; do
            local uid uname
            uid=$(echo "$user_json"  | jq -r '.id')
            uname=$(echo "$user_json" | jq -r '.username')
            echo "        -> ${uname}"

            # Credenciales
            local creds
            creds=$(kc_get "/admin/realms/${rname}/users/${uid}/credentials" 2>/dev/null || echo "[]")

            # Roles del realm (no compuestos)
            local realm_roles_raw realm_role_names
            realm_roles_raw=$(kc_get "/admin/realms/${rname}/users/${uid}/role-mappings/realm" 2>/dev/null || echo "[]")
            realm_role_names=$(echo "$realm_roles_raw" | jq '[.[] | select(.composite != true) | .name]')

            # Roles de clientes { "clientId": ["role1", ...] }
            local all_mappings client_roles
            all_mappings=$(kc_get "/admin/realms/${rname}/users/${uid}/role-mappings" 2>/dev/null || echo "{}")
            client_roles=$(echo "$all_mappings" | jq '
                .clientMappings // {} |
                to_entries |
                map({key: .key, value: [.value.mappings[]?.name]}) |
                from_entries')

            # Grupos (paths)
            local groups_raw group_paths
            groups_raw=$(kc_get "/admin/realms/${rname}/users/${uid}/groups" 2>/dev/null || echo "[]")
            group_paths=$(echo "$groups_raw" | jq '[.[].path]')

            # Merge en objeto completo
            local full_user
            full_user=$(echo "$user_json" | jq \
                --argjson creds       "$creds" \
                --argjson realmRoles  "$realm_role_names" \
                --argjson clientRoles "$client_roles" \
                --argjson groups      "$group_paths" \
                '. + {credentials: $creds, realmRoles: $realmRoles, clientRoles: $clientRoles, groups: $groups}')

            users_full=$(jq -n --argjson arr "$users_full" --argjson u "$full_user" '$arr + [$u]')
        done < <(echo "$all_users" | jq -c '.[]')

        realm_data=$(echo "$realm_data" | jq --argjson users "$users_full" '. + {users: $users}')

        local clients_n roles_n groups_n
        clients_n=$(echo "$realm_data" | jq '.clients | length')
        roles_n=$(echo  "$realm_data" | jq '.roles.realm | length')
        groups_n=$(echo "$realm_data" | jq '.groups | length')
        ok "'${rname}': ${users_count} usuarios | ${clients_n} clientes | ${roles_n} roles | ${groups_n} grupos"

        realms_json=$(jq -n --argjson arr "$realms_json" --argjson r "$realm_data" '$arr + [$r]')
    done < <(echo "$realms_raw" | jq -c '.[]')

    # JSON final de exportacion
    local export_date
    export_date=$(date -u +"%Y-%m-%dT%H:%M:%S")
    jq -n \
        --arg   date    "$export_date" \
        --arg   src     "$KC_URL" \
        --argjson realms "$realms_json" \
        '{export_date: $date, source_url: $src, realms: $realms}' > "$OUTPUT_FILE"

    echo ""
    echo "============================================================"
    ok "Exportacion completada -> ${OUTPUT_FILE}"
    echo "============================================================"
    jq -r '.realms[] |
        "  Realm \(.realm): \(.users | length) usuarios | \(.clients | length) clientes | \(.roles.realm | length) roles | \(.groups | length) grupos"
    ' "$OUTPUT_FILE"
}

# ==============================================================================
# IMPORT
# ==============================================================================
do_import() {
    echo "[*] Conectando a Keycloak: ${KC_URL}"
    authenticate
    ok "Autenticacion exitosa"; echo ""

    info "Archivo:      ${INPUT_FILE}"
    info "Fecha origen: $(jq -r '.export_date'  "$INPUT_FILE")"
    info "URL origen:   $(jq -r '.source_url'   "$INPUT_FILE")"
    info "Realms:       $(jq  '.realms | length' "$INPUT_FILE")"
    echo ""

    local existing_realms
    existing_realms=$(kc_get "/admin/realms" | jq -r '.[].realm')

    local total_realms realm_idx=0
    total_realms=$(jq '.realms | length' "$INPUT_FILE")

    while [[ $realm_idx -lt $total_realms ]]; do
        local realm_data rname
        realm_data=$(jq -c ".realms[$realm_idx]" "$INPUT_FILE")
        rname=$(echo "$realm_data" | jq -r '.realm')

        echo "[*] Importando realm: '${rname}'"

        # -- Realm existente --
        if echo "$existing_realms" | grep -qx "$rname"; then
            if [[ "$FORCE" == true ]]; then
                warn "Realm existente -> eliminando (--force)..."
                local del_st
                del_st=$(kc_delete "/admin/realms/${rname}")
                if [[ "$del_st" != "204" && "$del_st" != "404" ]]; then
                    err "No se pudo eliminar '${rname}': HTTP ${del_st}"
                    ((realm_idx++)); continue
                fi
                sleep 2; authenticate
            else
                warn "Ya existe. Usar --force para sobreescribir."
                ((realm_idx++)); continue
            fi
        fi

        # -- Crear realm (sin usuarios) --
        info "Creando realm..."
        local realm_no_users create_st
        realm_no_users=$(echo "$realm_data" | jq -c 'del(.users)')
        create_st=$(kc_post "/admin/realms" "$realm_no_users" | awk '{print $1}')

        if [[ "$create_st" != "201" && "$create_st" != "204" ]]; then
            err "Error creando realm '${rname}': HTTP ${create_st}"
            ((realm_idx++)); continue
        fi
        ok "Realm '${rname}' creado"
        sleep 1; authenticate

        # -- Indices para asignaciones --
        build_group_map "$rname"

        local role_map client_id_map
        role_map=$(kc_get "/admin/realms/${rname}/roles" \
            | jq 'map({key: .name, value: .}) | from_entries')
        client_id_map=$(kc_get "/admin/realms/${rname}/clients" \
            | jq 'map({key: .clientId, value: .id}) | from_entries')

        # -- Usuarios --
        local users_count user_idx=0
        users_count=$(echo "$realm_data" | jq '.users | length')
        info "Importando ${users_count} usuarios..."

        while [[ $user_idx -lt $users_count ]]; do
            local user_json uname
            user_json=$(echo "$realm_data" | jq -c ".users[$user_idx]")
            uname=$(echo "$user_json" | jq -r '.username')

            local realm_roles client_roles groups credentials
            realm_roles=$(echo  "$user_json" | jq -c '.realmRoles  // []')
            client_roles=$(echo "$user_json" | jq -c '.clientRoles // {}')
            groups=$(echo       "$user_json" | jq -c '.groups      // []')
            credentials=$(echo  "$user_json" | jq -c '.credentials // []')

            local user_clean
            user_clean=$(echo "$user_json" | jq -c \
                'del(.id, .createdTimestamp, .access, .realmRoles, .clientRoles, .groups, .credentials)')

            # Crear usuario
            local cu_result cu_status location new_uid
            cu_result=$(kc_post "/admin/realms/${rname}/users" "$user_clean")
            cu_status=$(echo "$cu_result" | awk '{print $1}')
            location=$(echo  "$cu_result" | awk '{print $2}' | tr -d ' \r\n')

            if [[ "$cu_status" != "201" && "$cu_status" != "204" ]]; then
                err "Error creando usuario '${uname}': HTTP ${cu_status}"
                ((user_idx++)); continue
            fi

            new_uid="${location##*/}"
            if [[ -z "$new_uid" || "$new_uid" == "$location" ]]; then
                new_uid=$(kc_get "/admin/realms/${rname}/users?username=${uname}&exact=true" \
                    | jq -r '.[0].id // empty' 2>/dev/null || true)
            fi
            if [[ -z "$new_uid" ]]; then
                warn "No se obtuvo ID para '${uname}', saltando asignaciones"
                ((user_idx++)); continue
            fi

            echo "        -> ${uname} (id=${new_uid})"

            # -- Credenciales --
            local cred_imported=false
            while IFS= read -r cred; do
                local has_secret has_value cred_payload
                has_secret=$(echo "$cred" | jq 'has("secretData") and has("credentialData")')
                has_value=$(echo  "$cred" | jq 'has("value")')

                if [[ "$has_secret" == "true" ]]; then
                    cred_payload=$(echo "$cred" | jq -c 'del(.id) |
                        {type, secretData, credentialData, priority: (.priority // 10), temporary: false}')
                elif [[ "$has_value" == "true" ]]; then
                    cred_payload=$(echo "$cred" | jq -c \
                        '{type, value, temporary: (.temporary // false)}')
                else
                    continue
                fi

                local cs
                cs=$(kc_put "/admin/realms/${rname}/users/${new_uid}/reset-password" "$cred_payload")
                if [[ "$cs" == "200" || "$cs" == "204" ]]; then
                    cred_imported=true
                else
                    warn "Credencial no importada: HTTP ${cs}"
                fi
            done < <(echo "$credentials" | jq -c '.[]' 2>/dev/null || true)

            if [[ "$cred_imported" == false ]]; then
                if [[ -n "$DEFAULT_PASSWORD" ]]; then
                    local pw_st
                    pw_st=$(kc_put "/admin/realms/${rname}/users/${new_uid}/reset-password" \
                        "{\"type\":\"password\",\"value\":\"${DEFAULT_PASSWORD}\",\"temporary\":true}")
                    [[ "$pw_st" == "200" || "$pw_st" == "204" ]] \
                        && echo "           [INFO] Contrasena temporal asignada (debe cambiarla al ingresar)" \
                        || warn "No se pudo asignar contrasena temporal: HTTP ${pw_st}"
                else
                    local req_actions
                    req_actions=$(echo "$user_clean" | jq -c '.requiredActions // [] | . + ["UPDATE_PASSWORD"] | unique')
                    kc_put "/admin/realms/${rname}/users/${new_uid}" \
                        "{\"requiredActions\":${req_actions}}" >/dev/null || true
                    echo "           [INFO] Sin hash exportable -> requiredAction=UPDATE_PASSWORD"
                fi
            fi

            # -- Roles del realm --
            local rr_count
            rr_count=$(echo "$realm_roles" | jq 'length')
            if [[ $rr_count -gt 0 ]]; then
                local roles_payload
                roles_payload=$(echo "$realm_roles" | jq -c \
                    --argjson map "$role_map" \
                    '[.[] | . as $n | $map[$n] | select(. != null)]')
                if [[ "$(echo "$roles_payload" | jq 'length')" -gt 0 ]]; then
                    local r_st
                    r_st=$(kc_post \
                        "/admin/realms/${rname}/users/${new_uid}/role-mappings/realm" \
                        "$roles_payload" | awk '{print $1}')
                    [[ "$r_st" != "200" && "$r_st" != "204" ]] && warn "Roles realm: HTTP ${r_st}"
                fi
            fi

            # -- Roles de clientes --
            while IFS="=" read -r cid roles_json; do
                local kc_cid avail to_assign
                kc_cid=$(echo "$client_id_map" | jq -r --arg c "$cid" '.[$c] // empty')
                [[ -z "$kc_cid" ]] && { warn "Cliente '${cid}' no encontrado"; continue; }

                avail=$(kc_get \
                    "/admin/realms/${rname}/users/${new_uid}/role-mappings/clients/${kc_cid}/available" \
                    2>/dev/null || echo "[]")
                to_assign=$(jq -n \
                    --argjson avail "$avail" \
                    --argjson names "$roles_json" \
                    '[$avail[] | select(.name as $n | $names | index($n) != null)]')
                if [[ "$(echo "$to_assign" | jq 'length')" -gt 0 ]]; then
                    kc_post "/admin/realms/${rname}/users/${new_uid}/role-mappings/clients/${kc_cid}" \
                        "$to_assign" >/dev/null || true
                fi
            done < <(echo "$client_roles" | jq -r 'to_entries[] | "\(.key)=\(.value | tojson)"')

            # -- Grupos --
            while IFS= read -r gpath; do
                local gid g_st
                gid=$(echo "$GROUP_MAP" | jq -r --arg p "$gpath" '.[$p] // empty')
                if [[ -n "$gid" ]]; then
                    g_st=$(kc_put "/admin/realms/${rname}/users/${new_uid}/groups/${gid}" "{}")
                    [[ "$g_st" != "200" && "$g_st" != "204" ]] && warn "Grupo '${gpath}': HTTP ${g_st}"
                else
                    warn "Grupo no encontrado: ${gpath}"
                fi
            done < <(echo "$groups" | jq -r '.[]')

            ((user_idx++))
        done

        ok "Realm '${rname}' importado exitosamente"
        ((realm_idx++))
    done

    echo ""
    echo "============================================================"
    ok "Importacion completada"
    echo "============================================================"
}

# ==============================================================================
# Uso
# ==============================================================================
usage() {
    cat <<'EOF'
keycloak_migrate.sh - Migra configuracion completa de Keycloak
Requiere: curl, jq

USO:
  # Exportar (genera keycloak_export_YYYYMMDD_HHMMSS.json)
  ./keycloak_migrate.sh export \
      --url http://localhost:8180 \
      --user admin \
      --password Admin2024!Secure

  # Exportar incluyendo realm master
  ./keycloak_migrate.sh export \
      --url http://localhost:8180 --user admin --password Pass \
      --include-master --output backup.json

  # Importar en nueva instancia
  ./keycloak_migrate.sh import \
      --url http://nueva:8180 --user admin --password NuevoPass \
      --file keycloak_export_20260422_170645.json \
      --default-password "Temporal2024!" \
      --force

OPCIONES EXPORT:
  --url URL               URL base de Keycloak
  --user USER             Usuario administrador
  --password PASS         Contrasena del administrador
  --output FILE           Archivo de salida (default: keycloak_export_<fecha>.json)
  --include-master        Incluir realm master en la exportacion
  --no-verify-ssl         Deshabilitar verificacion SSL

OPCIONES IMPORT:
  --url URL               URL base del Keycloak destino
  --user USER             Usuario administrador
  --password PASS         Contrasena del administrador
  --file FILE             Archivo JSON exportado previamente
  --force                 Eliminar y recrear realm si ya existe
  --default-password PASS Clave temporal para usuarios sin hash exportable
  --no-verify-ssl         Deshabilitar verificacion SSL
EOF
}

# ==============================================================================
# main
# ==============================================================================
main() {
    check_deps
    [[ $# -eq 0 ]] && { usage; exit 1; }

    local cmd="$1"; shift
    case "$cmd" in
        export|import) ;;
        help|-h|--help) usage; exit 0 ;;
        *) err "Comando desconocido: '${cmd}'. Usar: export | import"; exit 1 ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)              KC_URL="$2";             shift 2 ;;
            --user)             KC_USER="$2";            shift 2 ;;
            --password)         KC_PASS="$2";            shift 2 ;;
            --output)           OUTPUT_FILE="$2";        shift 2 ;;
            --file)             INPUT_FILE="$2";         shift 2 ;;
            --force)            FORCE=true;              shift   ;;
            --include-master)   INCLUDE_MASTER=true;     shift   ;;
            --default-password) DEFAULT_PASSWORD="$2";   shift 2 ;;
            --no-verify-ssl)    NO_SSL=true;             shift   ;;
            *) err "Argumento desconocido: $1"; exit 1  ;;
        esac
    done

    [[ -z "$KC_URL"  ]] && { err "Falta --url";      exit 1; }
    [[ -z "$KC_USER" ]] && { err "Falta --user";     exit 1; }
    [[ -z "$KC_PASS" ]] && { err "Falta --password"; exit 1; }

    if [[ "$cmd" == "export" ]]; then
        [[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="keycloak_export_$(date +%Y%m%d_%H%M%S).json"
        do_export
    else
        [[ -z "$INPUT_FILE" ]] && { err "Falta --file"; exit 1; }
        [[ ! -f "$INPUT_FILE" ]] && { err "Archivo no encontrado: ${INPUT_FILE}"; exit 1; }
        do_import
    fi
}

main "$@"
