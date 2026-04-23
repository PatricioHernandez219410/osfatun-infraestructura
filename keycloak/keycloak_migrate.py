#!/usr/bin/env python3
"""
keycloak_migrate.py
Export e import completo de configuracion Keycloak via Admin REST API.
Exporta: realms, roles, grupos, clientes, client-scopes, flujos de auth, usuarios y credenciales.

Uso:
  # Exportar desde la instancia actual
  python keycloak_migrate.py export \\
      --url http://localhost:8180 \\
      --user admin \\
      --password Admin2024!Secure

  # Importar en nueva instancia
  python keycloak_migrate.py import \\
      --url http://nueva-keycloak:8180 \\
      --user admin \\
      --password NuevoPass \\
      --file keycloak_export_<fecha>.json \\
      [--force]
"""

import argparse
import json
import sys
import time
import datetime

try:
    import requests
    from requests.packages.urllib3.exceptions import InsecureRequestWarning
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
except ImportError:
    print("[ERROR] Falta la libreria 'requests'. Instalar con: pip install requests")
    sys.exit(1)


# ==============================================================================
# Cliente Admin Keycloak
# ==============================================================================

class KeycloakAdmin:
    def __init__(self, url: str, username: str, password: str, verify_ssl: bool = False):
        self.url = url.rstrip("/")
        self.username = username
        self.password = password
        self.verify_ssl = verify_ssl
        self.token = None
        self._authenticate()

    def _authenticate(self):
        resp = requests.post(
            f"{self.url}/realms/master/protocol/openid-connect/token",
            data={
                "grant_type": "password",
                "client_id": "admin-cli",
                "username": self.username,
                "password": self.password,
            },
            verify=self.verify_ssl,
            timeout=30,
        )
        resp.raise_for_status()
        self.token = resp.json()["access_token"]

    def _headers(self):
        return {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }

    def get(self, path: str) -> dict | list:
        resp = requests.get(
            f"{self.url}{path}",
            headers=self._headers(),
            verify=self.verify_ssl,
            timeout=60,
        )
        resp.raise_for_status()
        return resp.json()

    def post(self, path: str, data=None) -> requests.Response:
        resp = requests.post(
            f"{self.url}{path}",
            headers=self._headers(),
            json=data,
            verify=self.verify_ssl,
            timeout=60,
        )
        return resp

    def put(self, path: str, data=None) -> requests.Response:
        resp = requests.put(
            f"{self.url}{path}",
            headers=self._headers(),
            json=data,
            verify=self.verify_ssl,
            timeout=60,
        )
        return resp

    def delete(self, path: str) -> requests.Response:
        resp = requests.delete(
            f"{self.url}{path}",
            headers=self._headers(),
            verify=self.verify_ssl,
            timeout=60,
        )
        return resp


# ==============================================================================
# Helpers
# ==============================================================================

def _get_all_users(kc: KeycloakAdmin, realm: str) -> list:
    """Obtiene usuarios paginando de 100 en 100."""
    users = []
    first = 0
    page_size = 100
    while True:
        batch = kc.get(
            f"/admin/realms/{realm}/users?first={first}&max={page_size}&briefRepresentation=false"
        )
        if not batch:
            break
        users.extend(batch)
        if len(batch) < page_size:
            break
        first += page_size
    return users


def _index_groups(groups: list, parent_path: str = "") -> dict:
    """Construye un mapa path -> id de grupos recursivamente."""
    result = {}
    for g in groups:
        path = f"/{g['name']}" if not parent_path else f"{parent_path}/{g['name']}"
        result[path] = g["id"]
        result.update(_index_groups(g.get("subGroups", []), path))
    return result


# ==============================================================================
# EXPORT
# ==============================================================================

def export_config(kc: KeycloakAdmin, skip_master: bool = True) -> dict:
    print("[*] Obteniendo lista de realms...")
    realms = kc.get("/admin/realms")

    export_data = {
        "export_date": datetime.datetime.now().isoformat(),
        "source_url": kc.url,
        "realms": [],
    }

    for realm_info in realms:
        realm_name = realm_info["realm"]
        if skip_master and realm_name == "master":
            print("    [~] Saltando realm 'master'")
            continue

        print(f"\n[*] Exportando realm: '{realm_name}'")

        # ------------------------------------------------------------------ #
        # 1. Partial export: settings base + clientes + grupos + roles        #
        # ------------------------------------------------------------------ #
        print("    [*] Configuracion base (partial-export)...")
        resp = requests.post(
            f"{kc.url}/admin/realms/{realm_name}/partial-export"
            "?exportClients=true&exportGroupsAndRoles=true",
            headers=kc._headers(),
            verify=kc.verify_ssl,
            timeout=60,
        )
        resp.raise_for_status()
        realm_data = resp.json()

        # ------------------------------------------------------------------ #
        # 2. Usuarios + detalles                                               #
        # ------------------------------------------------------------------ #
        print("    [*] Exportando usuarios...")
        users_raw = _get_all_users(kc, realm_name)
        print(f"        Encontrados: {len(users_raw)} usuarios")

        users_full = []
        for user in users_raw:
            uid  = user["id"]
            uname = user.get("username", uid)
            print(f"        -> {uname}")

            # Credenciales (puede incluir hash segun config del servidor)
            try:
                credentials = kc.get(f"/admin/realms/{realm_name}/users/{uid}/credentials")
            except Exception:
                credentials = []

            # Roles del realm asignados al usuario
            try:
                realm_roles_raw = kc.get(
                    f"/admin/realms/{realm_name}/users/{uid}/role-mappings/realm"
                )
                realm_role_names = [
                    r["name"] for r in realm_roles_raw if not r.get("composite")
                ]
            except Exception:
                realm_role_names = []

            # Roles de clientes asignados al usuario
            try:
                all_mappings = kc.get(
                    f"/admin/realms/{realm_name}/users/{uid}/role-mappings"
                )
                client_roles: dict[str, list[str]] = {}
                for cid, cdata in all_mappings.get("clientMappings", {}).items():
                    client_roles[cid] = [r["name"] for r in cdata.get("mappings", [])]
            except Exception:
                client_roles = {}

            # Grupos a los que pertenece el usuario
            try:
                groups_raw = kc.get(
                    f"/admin/realms/{realm_name}/users/{uid}/groups"
                )
                group_paths = [g["path"] for g in groups_raw]
            except Exception:
                group_paths = []

            users_full.append({
                **user,
                "credentials": credentials,
                "realmRoles": realm_role_names,
                "clientRoles": client_roles,
                "groups": group_paths,
            })

        realm_data["users"] = users_full

        # ------------------------------------------------------------------ #
        # 3. Estadisticas                                                      #
        # ------------------------------------------------------------------ #
        clients_n   = len(realm_data.get("clients", []))
        roles_n     = len(realm_data.get("roles", {}).get("realm", []))
        groups_n    = len(realm_data.get("groups", []))
        users_n     = len(users_full)
        print(f"    [OK] '{realm_name}': {users_n} usuarios | {clients_n} clientes | {roles_n} roles | {groups_n} grupos")

        export_data["realms"].append(realm_data)

    return export_data


# ==============================================================================
# IMPORT
# ==============================================================================

def import_config(kc: KeycloakAdmin, export_data: dict, force: bool = False, default_password: str | None = None):
    existing = {r["realm"] for r in kc.get("/admin/realms")}

    for realm_data in export_data["realms"]:
        realm_name = realm_data.get("realm")
        print(f"\n[*] Importando realm: '{realm_name}'")

        # ------------------------------------------------------------------ #
        # 0. Manejo de realm existente                                         #
        # ------------------------------------------------------------------ #
        if realm_name in existing:
            if force:
                print("    [!] Realm existente -> eliminando (--force)...")
                del_resp = kc.delete(f"/admin/realms/{realm_name}")
                if del_resp.status_code not in (204, 404):
                    print(f"    [ERROR] No se pudo eliminar: {del_resp.status_code}")
                    continue
                time.sleep(2)
                kc._authenticate()
            else:
                print(f"    [SKIP] Ya existe. Usar --force para sobreescribir.")
                continue

        # ------------------------------------------------------------------ #
        # 1. Crear realm (sin usuarios para mayor control)                     #
        # ------------------------------------------------------------------ #
        users = realm_data.pop("users", [])

        print(f"    [*] Creando realm...")
        create_resp = kc.post("/admin/realms", data=realm_data)
        if create_resp.status_code not in (201, 204):
            print(f"    [ERROR] {create_resp.status_code}: {create_resp.text[:300]}")
            realm_data["users"] = users
            continue

        print("    [OK] Realm creado")
        time.sleep(1)
        kc._authenticate()

        # ------------------------------------------------------------------ #
        # 2. Construir indices de grupos y roles para asignaciones            #
        # ------------------------------------------------------------------ #
        try:
            groups_list = kc.get(f"/admin/realms/{realm_name}/groups?max=1000")
            group_path_to_id = _index_groups(groups_list)
        except Exception:
            group_path_to_id = {}

        try:
            realm_roles_list = kc.get(f"/admin/realms/{realm_name}/roles")
            role_by_name: dict[str, dict] = {r["name"]: r for r in realm_roles_list}
        except Exception:
            role_by_name = {}

        try:
            clients_list = kc.get(f"/admin/realms/{realm_name}/clients")
            client_by_id: dict[str, str] = {c["clientId"]: c["id"] for c in clients_list}
        except Exception:
            client_by_id = {}

        # ------------------------------------------------------------------ #
        # 3. Importar usuarios                                                 #
        # ------------------------------------------------------------------ #
        print(f"    [*] Importando {len(users)} usuarios...")

        for user in users:
            uname = user.get("username", user.get("id"))

            # Extraer campos que se manejan por separado
            realm_roles_assign  = user.pop("realmRoles", [])
            client_roles_assign = user.pop("clientRoles", {})
            groups_assign       = user.pop("groups", [])
            credentials         = user.pop("credentials", [])

            # Limpiar campos internos que no deben enviarse al crear
            user.pop("id", None)
            user.pop("createdTimestamp", None)
            user.pop("access", None)

            # Crear usuario
            create_user = kc.post(f"/admin/realms/{realm_name}/users", data=user)
            if create_user.status_code not in (201, 204):
                print(f"        [ERROR] {uname}: {create_user.status_code} {create_user.text[:150]}")
                continue

            # Obtener ID del nuevo usuario desde Location header
            location = create_user.headers.get("Location", "")
            new_uid  = location.rstrip("/").split("/")[-1] if location else None

            if not new_uid:
                try:
                    found = kc.get(
                        f"/admin/realms/{realm_name}/users?username={uname}&exact=true"
                    )
                    new_uid = found[0]["id"] if found else None
                except Exception:
                    pass

            if not new_uid:
                print(f"        [WARN] No se obtuvo ID para '{uname}', saltando asignaciones")
                continue

            print(f"        -> {uname} (id={new_uid})")

            # -- Credenciales ----------------------------------------------- #
            # La Admin REST API de Keycloak NO expone el hash (secretData).
            # Solo se puede importar si el admin configuro exportacion a nivel DB.
            # Estrategia: intentar importar si hay datos completos; si no,
            # usar default_password o marcar UPDATE_PASSWORD.
            cred_imported = False
            for cred in credentials:
                cred.pop("id", None)
                if "secretData" in cred and "credentialData" in cred:
                    cred_payload = {
                        "type": cred.get("type", "password"),
                        "secretData": cred["secretData"],
                        "credentialData": cred["credentialData"],
                        "priority": cred.get("priority", 10),
                        "temporary": False,
                    }
                elif "value" in cred:
                    cred_payload = {
                        "type": cred.get("type", "password"),
                        "value": cred["value"],
                        "temporary": cred.get("temporary", False),
                    }
                else:
                    continue

                cred_resp = kc.put(
                    f"/admin/realms/{realm_name}/users/{new_uid}/reset-password",
                    data=cred_payload,
                )
                if cred_resp.status_code in (200, 204):
                    cred_imported = True
                else:
                    print(f"           [WARN] Credencial no importada: {cred_resp.status_code}")

            if not cred_imported:
                if default_password:
                    pw_resp = kc.put(
                        f"/admin/realms/{realm_name}/users/{new_uid}/reset-password",
                        data={"type": "password", "value": default_password, "temporary": True},
                    )
                    if pw_resp.status_code in (200, 204):
                        print(f"           [INFO] Contrasena temporal asignada (debe cambiarla al ingresar)")
                    else:
                        print(f"           [WARN] No se pudo asignar contrasena temporal: {pw_resp.status_code}")
                else:
                    # Marcar para que el usuario deba setear su contrasena
                    required_actions = list(set(user.get("requiredActions", []) + ["UPDATE_PASSWORD"]))
                    kc.put(
                        f"/admin/realms/{realm_name}/users/{new_uid}",
                        data={"requiredActions": required_actions},
                    )
                    print(f"           [INFO] Sin hash exportable -> requiredAction=UPDATE_PASSWORD")

            # -- Roles del realm -------------------------------------------- #
            if realm_roles_assign:
                roles_payload = [
                    role_by_name[r] for r in realm_roles_assign if r in role_by_name
                ]
                if roles_payload:
                    r_resp = kc.post(
                        f"/admin/realms/{realm_name}/users/{new_uid}/role-mappings/realm",
                        data=roles_payload,
                    )
                    if r_resp.status_code not in (200, 204):
                        print(f"           [WARN] Roles realm: {r_resp.status_code}")

            # -- Roles de clientes ------------------------------------------ #
            for client_id_str, role_names in client_roles_assign.items():
                kc_client_id = client_by_id.get(client_id_str)
                if not kc_client_id:
                    print(f"           [WARN] Cliente '{client_id_str}' no encontrado")
                    continue
                try:
                    available = kc.get(
                        f"/admin/realms/{realm_name}/users/{new_uid}"
                        f"/role-mappings/clients/{kc_client_id}/available"
                    )
                    to_assign = [r for r in available if r["name"] in role_names]
                    if to_assign:
                        kc.post(
                            f"/admin/realms/{realm_name}/users/{new_uid}"
                            f"/role-mappings/clients/{kc_client_id}",
                            data=to_assign,
                        )
                except Exception as e:
                    print(f"           [WARN] Roles cliente '{client_id_str}': {e}")

            # -- Grupos -------------------------------------------------------- #
            for gpath in groups_assign:
                gid = group_path_to_id.get(gpath)
                if gid:
                    g_resp = kc.put(
                        f"/admin/realms/{realm_name}/users/{new_uid}/groups/{gid}"
                    )
                    if g_resp.status_code not in (200, 204):
                        print(f"           [WARN] Grupo '{gpath}': {g_resp.status_code}")
                else:
                    print(f"           [WARN] Grupo no encontrado: {gpath}")

        realm_data["users"] = users
        print(f"    [OK] Realm '{realm_name}' importado exitosamente")


# ==============================================================================
# CLI
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Migra configuracion completa de Keycloak entre instancias",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ejemplos:
  # Exportar (genera keycloak_export_YYYYMMDD_HHMMSS.json)
  python keycloak_migrate.py export \\
      --url http://localhost:8180 \\
      --user admin \\
      --password Admin2024!Secure

  # Exportar incluyendo realm master
  python keycloak_migrate.py export \\
      --url http://localhost:8180 \\
      --user admin \\
      --password Admin2024!Secure \\
      --include-master \\
      --output mi_backup.json

  # Importar en nueva instancia (sobreescribir si ya existe)
  # --default-password asigna clave temporal a usuarios sin hash exportable
  python keycloak_migrate.py import \\
      --url http://nueva-instancia:8180 \\
      --user admin \\
      --password NuevoPass \\
      --file keycloak_export_20250422_120000.json \\
      --force
        """,
    )

    sub = parser.add_subparsers(dest="command", required=True)

    # ---- Export ----
    ep = sub.add_parser("export", help="Exportar configuracion desde Keycloak")
    ep.add_argument("--url",      required=True, help="URL base de Keycloak (ej: http://localhost:8180)")
    ep.add_argument("--user",     required=True, help="Usuario administrador")
    ep.add_argument("--password", required=True, help="Contrasena del administrador")
    ep.add_argument("--output",   default=None,  help="Ruta del archivo JSON de salida")
    ep.add_argument("--include-master", action="store_true", help="Incluir realm master en la exportacion")
    ep.add_argument("--no-verify-ssl",  action="store_true", help="Deshabilitar verificacion de certificado SSL")

    # ---- Import ----
    ip = sub.add_parser("import", help="Importar configuracion a Keycloak")
    ip.add_argument("--url",      required=True, help="URL base del Keycloak destino")
    ip.add_argument("--user",     required=True, help="Usuario administrador")
    ip.add_argument("--password", required=True, help="Contrasena del administrador")
    ip.add_argument("--file",     required=True, help="Archivo JSON exportado previamente")
    ip.add_argument("--force",    action="store_true", help="Sobreescribir realms existentes (DELETE + CREATE)")
    ip.add_argument("--default-password", default=None,
                    help="Contrasena temporal para usuarios cuya clave no pudo exportarse (se marca como temporal)")
    ip.add_argument("--no-verify-ssl", action="store_true", help="Deshabilitar verificacion de certificado SSL")

    args = parser.parse_args()
    verify = not args.no_verify_ssl

    print(f"[*] Conectando a Keycloak: {args.url}")
    try:
        kc = KeycloakAdmin(
            url=args.url,
            username=args.user,
            password=args.password,
            verify_ssl=verify,
        )
        print("[OK] Autenticacion exitosa\n")
    except requests.exceptions.ConnectionError:
        print(f"[ERROR] No se puede conectar a {args.url}")
        sys.exit(1)
    except requests.exceptions.HTTPError as e:
        print(f"[ERROR] Autenticacion fallida: {e}")
        sys.exit(1)

    if args.command == "export":
        data = export_config(kc, skip_master=not args.include_master)

        out = args.output or f"keycloak_export_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)

        print(f"\n{'='*60}")
        print(f"[OK] Exportacion completada -> {out}")
        print(f"{'='*60}")
        total_users = sum(len(r.get("users", [])) for r in data["realms"])
        for r in data["realms"]:
            print(
                f"  Realm '{r['realm']}': "
                f"{len(r.get('users', []))} usuarios | "
                f"{len(r.get('clients', []))} clientes | "
                f"{len(r.get('roles', {}).get('realm', []))} roles | "
                f"{len(r.get('groups', []))} grupos"
            )
        print(f"  Total usuarios exportados: {total_users}")

    elif args.command == "import":
        with open(args.file, "r", encoding="utf-8") as fh:
            data = json.load(fh)

        print(f"[*] Archivo de exportacion: {args.file}")
        print(f"    Fecha origen:  {data.get('export_date', 'desconocida')}")
        print(f"    URL origen:    {data.get('source_url', 'desconocida')}")
        print(f"    Realms en archivo: {len(data.get('realms', []))}\n")

        import_config(kc, data, force=args.force, default_password=args.default_password)

        print(f"\n{'='*60}")
        print("[OK] Importacion completada")
        print(f"{'='*60}")


if __name__ == "__main__":
    main()
