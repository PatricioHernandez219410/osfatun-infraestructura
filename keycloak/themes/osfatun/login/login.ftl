<#import "template.ftl" as layout>
<@layout.registrationLayout displayInfo=false displayMessage=false; section>
  <#if section = "form">

    <#assign isAdmin = (client.clientId!'') == "osfatun-admin">

    <div class="os-page<#if isAdmin> os-page--admin</#if>">

      <!-- ══════════════════════════════════
           COLUMNA IZQUIERDA — Branding
           ══════════════════════════════════ -->
      <div class="os-left">

        <div class="os-left-inner">
          <img src="${url.resourcesPath}/img/logo.png" alt="OSFATUN" class="os-logo-img" />

          <div class="os-hero">
            <#if isAdmin>
              <div class="os-admin-badge">
                <svg width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5"
                    d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/>
                </svg>
                Acceso Restringido
              </div>
              <h1 class="os-hero-title">Panel de<br><em>Administraci&oacute;n</em></h1>
              <p class="os-hero-desc">Acceso exclusivo para administradores<br>del sistema OSFATUN.</p>
            <#else>
              <h1 class="os-hero-title">Sistema de<br><em>Gesti&oacute;n Integral</em></h1>
              <p class="os-hero-desc">Administraci&oacute;n de beneficiarios, prestaciones,<br>recaudaci&oacute;n y reportes OSFATUN.</p>
            </#if>
          </div>
        </div>

      </div><!-- /os-left -->

      <!-- ══════════════════════════════════
           COLUMNA DERECHA — Formulario
           ══════════════════════════════════ -->
      <div class="os-right">

        <div class="os-card">

          <!-- Cabecera -->
          <div class="os-card-header">
            <#if isAdmin>
              <h2 class="os-card-title">Acceso Administrador</h2>
              <p class="os-card-subtitle">Ingres&aacute; tus credenciales de administrador</p>
            <#else>
              <h2 class="os-card-title">Iniciar sesi&oacute;n</h2>
              <p class="os-card-subtitle">Ingres&aacute; tus credenciales para continuar</p>
            </#if>
          </div>

          <!-- Alerta de error/warning -->
          <#if message?has_content && (message.type = 'error' || message.type = 'warning')>
            <div class="os-alert">
              <svg class="os-alert-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                  d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
              </svg>
              <span>${kcSanitize(message.summary)?no_esc}</span>
            </div>
          </#if>

          <!-- Formulario -->
          <form id="kc-form-login" action="${url.loginAction}" method="post">

            <div class="os-field">
              <label for="username">USUARIO</label>
              <div class="os-input-wrap">
                <span class="os-input-icon">
                  <svg width="17" height="17" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                      d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/>
                  </svg>
                </span>
                <input id="username" name="username" type="text"
                       autofocus autocomplete="username"
                       placeholder="admin"
                       value="${(login.username!'')}" />
              </div>
            </div>

            <div class="os-field">
              <label for="password">CONTRASE&Ntilde;A</label>
              <div class="os-input-wrap">
                <span class="os-input-icon">
                  <svg width="17" height="17" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                      d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/>
                  </svg>
                </span>
                <input id="password" name="password" type="password"
                       autocomplete="current-password"
                       placeholder="&bull;&bull;&bull;&bull;&bull;&bull;&bull;&bull;" />
                <button type="button" class="os-eye-btn" onclick="togglePassword()" aria-label="Mostrar contrase&ntilde;a">
                  <svg id="eye-icon" width="17" height="17" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                      d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                      d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>
                  </svg>
                </button>
              </div>
            </div>

            <div id="kc-form-buttons">
              <button class="os-btn-submit" type="submit">
                <svg width="17" height="17" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.2"
                    d="M11 16l-4-4m0 0l4-4m-4 4h14m-5 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h7a3 3 0 013 3v1"/>
                </svg>
                Ingresar al sistema
              </button>
            </div>

          </form>

          <!-- Social login — Google (solo si está configurado en el realm) -->
          <#if social?? && social.providers?has_content>
            <div class="os-divider"><span></span></div>
            <#list social.providers as p>
              <#if p.alias == "google">
                <a href="${p.loginUrl}" class="os-btn-google">
                  <svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <path d="M17.64 9.205c0-.639-.057-1.252-.164-1.841H9v3.481h4.844a4.14 4.14 0 01-1.796 2.716v2.259h2.908c1.702-1.567 2.684-3.875 2.684-6.615z" fill="#4285F4"/>
                    <path d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 009 18z" fill="#34A853"/>
                    <path d="M3.964 10.71A5.41 5.41 0 013.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 000 9c0 1.452.348 2.827.957 4.042l3.007-2.332z" fill="#FBBC05"/>
                    <path d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 00.957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58z" fill="#EA4335"/>
                  </svg>
                  Ingresar con cuenta de Google
                </a>
              </#if>
            </#list>
          </#if>

          <#if realm.resetPasswordAllowed>
            <div class="os-links">
              <a href="${url.loginResetCredentialsUrl}">&iquest;Olvidaste tu contrase&ntilde;a?</a>
            </div>
          </#if>

        </div><!-- /os-card -->

      </div><!-- /os-right -->

      <div class="os-footer">
        &copy; ${.now?string('yyyy')} OSFATUN &mdash; Todos los derechos reservados
      </div>

    </div><!-- /os-page -->

    <script>
      function togglePassword() {
        var input = document.getElementById('password');
        var icon  = document.getElementById('eye-icon');
        if (input.type === 'password') {
          input.type = 'text';
          icon.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"/>';
        } else {
          input.type = 'password';
          icon.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>';
        }
      }
    </script>

  </#if>
</@layout.registrationLayout>
