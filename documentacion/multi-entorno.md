# Estrategia Multi-Entorno — Diseño de Implementación

## Contexto

El cluster ejecuta una única instancia de Pomerium (ingress controller) y una única instancia de Keycloak (IdP). Pomerium está vinculado a un solo Identity Provider (el CRD `Pomerium` es cluster-global y no soporta múltiples IdP por ruta). Esto impide usar un realm distinto de Keycloak por entorno sin levantar una segunda instancia de Pomerium, lo cual requiere un dominio `authenticate` adicional que hoy no está disponible.

## Decisión

Todos los entornos comparten el **realm `osfatun`** en Keycloak. La separación de usuarios se logra mediante **grupos de entorno** (`ENT-Desarrollo`, `ENT-QA`, etc.) que actúan en dos niveles:

1. **Pomerium** — gate-keeping de rutas por grupo de entorno.
2. **Backend** — scoping de la gestión de usuarios al grupo de entorno configurado.

## Arquitectura

```
                          Keycloak (realm: osfatun)
                          ├── Grupo: ENT-Desarrollo
                          ├── Grupo: ENT-QA
                          ├── Grupo: admin (ArgoCD)
                          ├── Grupo: Administradores (rol)
                          ├── Grupo: Operadores (rol)
                          ├── Grupo: Auditores (rol)
                          └── Grupo: Consulta (rol)

             ┌──────────────────────────┐
             │        Pomerium          │
             │  (único ingress, un IdP) │
             └──────────┬───────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
   ┌────▼────┐    ┌─────▼────┐    ┌─────▼────┐
   │  DESA   │    │   QA     │    │  ArgoCD  │
   │ policy: │    │ policy:  │    │ policy:  │
   │ENT-Desa │    │ ENT-QA   │    │  admin   │
   └────┬────┘    └────┬─────┘    └──────────┘
        │              │
   ┌────▼────┐    ┌────▼─────┐
   │Backend  │    │Backend   │
   │ENV_GROUP│    │ENV_GROUP │
   │=ENT-Desa│    │=ENT-QA   │
   └─────────┘    └──────────┘
```

### Flujo de un usuario

1. El usuario accede a un servicio (ej: `empleados.qa.osfatun.com.ar`).
2. **Pomerium** redirige a Keycloak para autenticar. El usuario se logea en el realm `osfatun`.
3. Pomerium recibe el token con el claim `groups` (array plano, `full.path: false`).
4. La policy del Ingress evalúa `claim/groups` contiene `ENT-QA` → acceso concedido o denegado.
5. El frontend carga y autentica via keycloak-js contra el mismo realm `osfatun`.
6. El frontend llama al backend QA con el JWT.
7. El backend QA tiene `KEYCLOAK_ENVIRONMENT_GROUP=ENT-QA` y filtra todas las operaciones de gestión de usuarios a ese grupo.

### Asignación de usuarios

Un usuario pertenece a:
- **Un grupo de entorno** (o varios, si necesita acceder a múltiples entornos): `ENT-Desarrollo`, `ENT-QA`.
- **Uno o más grupos de rol**: `Administradores`, `Operadores`, etc.
- Opcionalmente al grupo `admin` para acceso a ArgoCD.

Los grupos de entorno y de rol son **independientes y planos** (no anidados). Esto funciona porque el mapper `groups` tiene `full.path: false`, devolviendo nombres de grupo sin path.

---

## Cambios en la infraestructura (ya implementados)

### 1. Backend Helm Chart

- **`values.yaml`** — nuevo campo `keycloak.environmentGroup` (default: `""`).
- **`secret-config.yaml`** — nueva env var `KEYCLOAK_ENVIRONMENT_GROUP`.

### 2. Keycloak Realm ConfigMap

- **`keycloak-realm-configmap.yaml`** — agregados grupos `ENT-Desarrollo` y `ENT-QA`.
- **IMPORTANTE**: el ConfigMap solo afecta el primer arranque (`--import-realm`). En un realm existente, los grupos deben crearse manualmente desde la UI de Keycloak.

### 3. ArgoCD Application YAMLs para QA

- `argocd/osfatun-backend-qa.yaml` — `keycloak.environmentGroup=ENT-QA`, namespace `osfatun-qa`.
- `argocd/osfatun-frontend-qa.yaml` — policy con `ENT-QA`, namespace `qa`.
- `argocd/osfatun-frontend-usuario-qa.yaml` — policy con `ENT-QA`, namespace `qa`.

### 4. Application YAMLs de desarrollo actualizados

- `argocd/osfatun-backend.yaml` — agregado `keycloak.environmentGroup=ENT-Desarrollo`.
- `argocd/osfatun-frontend.yaml` — ejemplo de policy actualizado a `ENT-Desarrollo`.
- `argocd/osfatun-frontend-usuario.yaml` — ejemplo de policy actualizado a `ENT-Desarrollo`.

---

## Cambios requeridos en el backend (pendiente de implementar)

El backend Django debe leer `KEYCLOAK_ENVIRONMENT_GROUP` y usarla para delimitar la gestión de usuarios. Los cambios se concentran en la capa de servicio que interactúa con la Keycloak Admin API.

### Lectura de la variable

```python
# settings.py o donde se lean las env vars de Keycloak
KEYCLOAK_ENVIRONMENT_GROUP = os.environ.get("KEYCLOAK_ENVIRONMENT_GROUP", "")
```

### Comportamiento esperado

| Operación | Sin `ENVIRONMENT_GROUP` (vacío) | Con `ENVIRONMENT_GROUP` |
|---|---|---|
| **Listar usuarios** | Lista todos los usuarios del realm | Lista solo miembros del grupo configurado |
| **Crear usuario** | Crea usuario sin grupo de entorno | Crea usuario y lo asigna al grupo de entorno |
| **Editar usuario** | Sin restricción | Solo permite editar usuarios del grupo |
| **Eliminar/desactivar** | Sin restricción | Solo permite operar sobre usuarios del grupo |

### Endpoints de la Keycloak Admin API involucrados

- **Listar miembros del grupo:** `GET /admin/realms/{realm}/groups/{groupId}/members`
  - Requiere primero obtener el `groupId` por nombre: `GET /admin/realms/{realm}/groups?search={groupName}`
- **Asignar usuario a grupo:** `PUT /admin/realms/{realm}/users/{userId}/groups/{groupId}`
- **Verificar membresía:** `GET /admin/realms/{realm}/users/{userId}/groups`

### Consideraciones

- Si `KEYCLOAK_ENVIRONMENT_GROUP` está vacío, el backend debe funcionar sin filtrado (retrocompatibilidad).
- El `ensure_admin` (management command) debe asignar el admin inicial al grupo de entorno configurado además de sus roles actuales.
- La paginación al listar miembros del grupo se maneja con `first` y `max` en la query string.

---

## Pasos para levantar el entorno QA

### Prerequisitos

1. El realm `osfatun` ya existe y funciona.
2. Pomerium está integrado con Keycloak.
3. Los Application YAMLs de QA están en el repo.

### Ejecución

1. **Keycloak — Crear grupo `ENT-QA`:**
   - Acceder a la consola de Keycloak → Realm `osfatun` → Groups → Create group → `ENT-QA`.

2. **Keycloak — Crear grupo `ENT-Desarrollo`** (si no existe):
   - Mismo procedimiento. Asignar los usuarios de desarrollo existentes a este grupo.

3. **PostgreSQL — Crear base de datos QA:**
   ```bash
   kubectl exec -it -n database main-db-1 -- psql -U postgres \
     -c "CREATE DATABASE osfatun_qa OWNER app;"
   ```

4. **DNS — Crear registros A** para los dominios QA (backend API, frontend empleados, frontend admin) apuntando a la IP del nodo control-plane.

5. **ArgoCD — Aplicar los Application YAMLs de QA:**
   ```bash
   kubectl apply -f argocd/osfatun-backend-qa.yaml
   kubectl apply -f argocd/osfatun-frontend-qa.yaml
   kubectl apply -f argocd/osfatun-frontend-usuario-qa.yaml
   ```

6. **ArgoCD UI — Cargar parameters sensibles** para cada app QA (misma planilla que desarrollo, valores independientes).

7. **ArgoCD UI — Configurar `ingress.policy`** en los frontends QA:
   ```json
   [{"allow":{"and":[{"claim/groups":"ENT-QA"}]}}]
   ```

8. **Sincronizar** las tres apps desde ArgoCD.

9. **Backend — Implementar filtrado por grupo** (ver sección anterior). Hasta que se implemente, el panel-usuarios de QA mostrará todos los usuarios del realm (funcional pero sin aislamiento).

---

## Evolución futura: migración a realms separados

Si se obtiene un segundo dominio `authenticate` (ej: `authenticate-qa.prueba.ticksar.com.ar`):

1. Desplegar un segundo operador de Pomerium con IngressClass `pomerium-qa`.
2. Crear realm `osfatun-qa` en Keycloak.
3. Migrar usuarios del grupo `ENT-QA` al nuevo realm.
4. Cambiar `ingressClassName` de los charts QA a `pomerium-qa`.
5. Configurar el backend QA con `keycloak.realm=osfatun-qa`.
6. Eliminar el grupo `ENT-QA` del realm original.

La variable `KEYCLOAK_ENVIRONMENT_GROUP` quedaría vacía en cada backend (ya que cada realm solo tiene sus propios usuarios), manteniendo retrocompatibilidad.
