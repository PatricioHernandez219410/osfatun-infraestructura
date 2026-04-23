<#macro registrationLayout bodyClass="" displayInfo=false displayMessage=true displayRequiredFields=false displayWide=false showAnotherWayIfPresent=true>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>OSFATUN — Iniciar sesión</title>
    <link rel="icon" type="image/png" href="${url.resourcesPath}/img/favicon.png" />
    <link rel="apple-touch-icon" href="${url.resourcesPath}/img/favicon.png" />
    <link rel="stylesheet" href="${url.resourcesPath}/css/login.css" />
</head>
<body>
    <#nested "form">
</body>
</html>
</#macro>
