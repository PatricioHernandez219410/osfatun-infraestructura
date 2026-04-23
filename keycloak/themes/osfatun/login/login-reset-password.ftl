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

          <!-- Cabecera con flecha volver -->
          <div class="os-card-header os-card-header--reset">
            <a href="${url.loginUrl}" class="os-back-btn" aria-label="Volver al inicio de sesi&oacute;n">
              <svg width="18" height="18" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                  d="M15 19l-7-7 7-7"/>
              </svg>
            </a>
            <div class="os-card-header-text">
              <h2 class="os-card-title">Recuperar contrase&ntilde;a</h2>
              <p class="os-card-subtitle">Ingres&aacute; tu documento para recibir instrucciones</p>
            </div>
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

          <!-- Info box -->
          <div class="os-info-box">
            <svg width="17" height="17" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
            </svg>
            <span>Le enviaremos un enlace de recuperaci&oacute;n al email registrado en el sistema.</span>
          </div>

          <!-- Formulario -->
          <form id="kc-reset-password-form" action="${url.loginAction}" method="post">

            <div class="os-field">
              <label for="username">DNI / CUIL / CUIT / MAIL</label>
              <div class="os-input-wrap">
                <span class="os-input-icon">
                  <svg width="17" height="17" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                      d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/>
                  </svg>
                </span>
                <input id="username" name="username" type="text"
                       autofocus autocomplete="username"
                       placeholder="Ej: 32456789 &oacute; 20-32456789-1"
                       value="${(auth.attemptedUsername!'')}" />
              </div>
            </div>

            <div id="kc-form-buttons">
              <button class="os-btn-reset" type="submit">
                <svg width="17" height="17" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                    d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/>
                </svg>
                Buscar y enviar enlace
              </button>
            </div>

          </form>

        </div><!-- /os-card -->

      </div><!-- /os-right -->

      <div class="os-footer">
        &copy; ${.now?string('yyyy')} OSFATUN &mdash; Todos los derechos reservados
      </div>

    </div><!-- /os-page -->

  </#if>
</@layout.registrationLayout>
