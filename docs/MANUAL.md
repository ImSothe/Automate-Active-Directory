# Manual de instalación y uso

> También disponible en PDF: [Manual-Automate-Active-Directory.pdf](Manual-Automate-Active-Directory.pdf)

Este manual te lleva de cero a tener la herramienta funcionando, en tres niveles. Haz el **nivel 1** hoy mismo (10 minutos); los otros dos cuando quieras probarla "de verdad".

| Nivel | Qué pruebas | Qué necesitas | Tiempo |
| --- | --- | --- | --- |
| **1. Modo Lab** | Toda la herramienta con un AD y un Microsoft 365 **simulados** | Tu PC (Windows, Mac o Linux) | 10 min |
| **2. Laboratorio con Active Directory real** | Usuarios, OUs, grupos y permisos NTFS **reales** | Una máquina virtual con Windows Server (gratis 180 días) | 1–2 h |
| **3. Microsoft 365 (opcional)** | Sincronización con Entra ID, licencias y revocación de sesiones | Un tenant de pruebas de Microsoft 365 | 1–2 h |

> **Regla de oro:** nunca la pruebes por primera vez contra el Active Directory de una empresa. Usa siempre un laboratorio.

---

## Índice

1. [Descargar la herramienta](#1-descargar-la-herramienta)
2. [Nivel 1 — Modo Lab en tu PC](#2-nivel-1--modo-lab-en-tu-pc)
3. [Nivel 2 — Laboratorio con Active Directory real](#3-nivel-2--laboratorio-con-active-directory-real)
4. [Nivel 3 — Conectar Microsoft 365 (opcional)](#4-nivel-3--conectar-microsoft-365-opcional)
5. [Uso del día a día](#5-uso-del-día-a-día)
6. [Lista de pruebas (checklist)](#6-lista-de-pruebas-checklist)
7. [Problemas frecuentes](#7-problemas-frecuentes)
8. [Limpiar / desinstalar](#8-limpiar--desinstalar)

---

## 1. Descargar la herramienta

El repositorio es **privado**, así que necesitas estar conectado con tu cuenta de GitHub.

**Opción A — con Git** (recomendada, así luego actualizas con `git pull`):

```powershell
winget install --id Git.Git -e          # si no tienes Git
git clone https://github.com/ImSothe/Automate-Active-Directory.git
cd Automate-Active-Directory
```

**Opción B — ZIP:** en la página del repositorio → botón verde **Code** → **Download ZIP** → descomprímelo.

**Desbloquear los ficheros (solo Windows, importante):** Windows marca los ficheros descargados de Internet y PowerShell se niega a ejecutarlos. Desde la carpeta de la herramienta:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

---

## 2. Nivel 1 — Modo Lab en tu PC

### 2.1 Instalar PowerShell 7

Funciona también con el Windows PowerShell 5.1 que trae Windows, pero PowerShell 7 es más rápido y es el que se usa en Mac/Linux.

```powershell
winget install --id Microsoft.PowerShell -e
```

Abre **PowerShell 7** (busca "pwsh" en el menú inicio).

### 2.2 Arrancar la interfaz

```powershell
cd C:\ruta\a\Automate-Active-Directory
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass   # solo afecta a esta ventana
.\scripts\Start-UI.ps1
```

Verás algo así:

```
  UserLifecycle - interfaz web
  Modo: Lab   Organización: Contoso Iberia
  Abre esta URL (lleva el token de esta sesión: no la compartas):
  http://localhost:8787/?t=4f1c...
```

En Windows se abre el navegador solo. Si no, copia la URL **completa** (con el `?t=...`). Para parar el servidor: **Ctrl + C**.

> El aviso amarillo *"Usando la configuración de ejemplo"* es normal: estás en modo Lab con datos ficticios de "Contoso". Se crea una carpeta `data/` con el directorio simulado, el log y los informes.

### 2.3 Recorrido guiado (5 minutos)

1. **Alta con colisión de nombre.** Pestaña *Alta*: Nombre `juan`, Apellidos `GARCÍA LÓPEZ`, Departamento `Ventas`, Puesto `Jefe de Ventas`, Responsable `lmartinez` → **Revisar plan**.
   Fíjate en que normaliza el nombre (*Juan García López*), que `jgarcia` ya existe y propone `jgarcial`, y que por ser "Jefe" añade el grupo *GG-Responsables*. → **Crear usuario**. Copia la contraseña: no se vuelve a mostrar.
2. **Licencias agotadas.** Haz otra alta en *Finanzas*. El resultado sale *"Completada con avisos"* porque no quedan licencias `POWER_BI_PRO` (lo verás en *Auditoría → Licencias de Microsoft 365*).
3. **Validación.** Prueba a poner `<script>` como nombre o un responsable que no existe (`noexiste`): el plan sale **Bloqueado** y el botón de crear se desactiva.
4. **Baja.** Pestaña *Baja* → busca `ruiz` → selecciona a *Ana Ruiz Martín*. Revisa qué grupos y licencias se le van a quitar, escribe un motivo, escribe `aruiz` para confirmar → **Dar de baja**.
5. **Auditoría.** Pestaña *Auditoría* → **Verificar integridad del log** → abre un **Informe**.
6. **Prueba de manipulación del log.** Abre `data/audit/audit-log.jsonl` con el Bloc de notas, cambia una letra de la **primera** línea y guarda. Vuelve a pulsar *Verificar integridad*: te dirá en qué línea se rompió la cadena.

Para empezar de cero:

```powershell
Import-Module .\src\UserLifecycle
Reset-LifecycleLab -IncludeAudit -Confirm:$false
```

### 2.4 Lo mismo desde la consola

```powershell
Import-Module .\src\UserLifecycle

# ¿Qué haría? (no cambia nada)
Get-LifecycleOnboardingPlan -GivenName 'Lucía' -Surname 'Fernández de la Vega' -Department Marketing -Title 'Técnica de Marketing'

# Alta
$r = New-LifecycleUser -GivenName 'Lucía' -Surname 'Fernández de la Vega' -Department Marketing -Title 'Técnica de Marketing' -Ticket 'RRHH-1'
$r.Steps | Format-Table Status, Name, Detail
[System.Net.NetworkCredential]::new('', $r.InitialPassword).Password   # ver la contraseña

# Baja (pide confirmación)
Disable-LifecycleUser -Identity lfernandez -Reason 'Fin de contrato' -Ticket 'RRHH-2'

# Altas masivas desde CSV (primero en simulacro)
.\scripts\Invoke-BulkOnboarding.ps1 -CsvPath .\examples\altas.csv -WhatIf
.\scripts\Invoke-BulkOnboarding.ps1 -CsvPath .\examples\altas.csv
```

Todos los comandos tienen ayuda: `Get-Help New-LifecycleUser -Full`.

---

## 3. Nivel 2 — Laboratorio con Active Directory real

Vas a montar un dominio `contoso.local` en una máquina virtual. Todo es gratis.

### 3.1 Crear la máquina virtual

1. **Hipervisor:**
   - Windows 10/11 **Pro**: activa Hyper-V → `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All` (como administrador) y reinicia.
   - Windows Home, Mac o Linux: instala **VirtualBox**.
2. **ISO:** descarga **Windows Server 2025 (o 2022) Evaluation** desde el *Microsoft Evaluation Center* (búscalo en Google). Es legal y dura 180 días.
3. **VM:** 2 vCPU, 4 GB de RAM (mejor 6), disco de 60 GB, red con salida a Internet.
4. Instala Windows Server eligiendo **"Desktop Experience"** (con escritorio). Pon una contraseña de administrador que recuerdes.
5. **Haz un checkpoint/instantánea** de la VM recién instalada. Si algo sale mal, vuelves aquí en segundos.

### 3.2 Convertirla en controlador de dominio

Dentro de la VM, abre **PowerShell como administrador**:

```powershell
# 1) Nombre del servidor (la configuración de ejemplo lo usará como servidor de ficheros)
Rename-Computer -NewName DC01 -Restart
```

Tras reiniciar, otra vez PowerShell como administrador:

```powershell
# 2) Instalar Active Directory
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

# 3) Crear el dominio contoso.local (te pedirá una contraseña de "modo seguro": apúntala)
Install-ADDSForest -DomainName 'contoso.local' -DomainNetbiosName 'CONTOSO' -InstallDns `
    -SafeModeAdministratorPassword (Read-Host 'Contraseña DSRM' -AsSecureString) -Force
```

El servidor se reinicia solo. Entra como **CONTOSO\Administrador** (o *Administrator* si está en inglés).

> Ahora es buen momento para **otro checkpoint**: "dominio recién creado".

### 3.3 Copiar la herramienta a la VM

Cualquiera de estas vale:
- Instala Git en la VM y haz `git clone` (sección 1).
- Descarga el ZIP desde el navegador de la VM.
- Copia la carpeta desde tu PC (en Hyper-V: *Sesión mejorada* permite copiar y pegar).

Luego, en la carpeta de la herramienta: `Get-ChildItem -Recurse | Unblock-File`

### 3.4 Configurar

```powershell
cd C:\Automate-Active-Directory          # o donde la hayas puesto
Copy-Item .\config\settings.example.json .\config\settings.json
notepad .\config\settings.json
```

Cambia **solo** esto:

| Clave | Valor para el laboratorio |
| --- | --- |
| `"Mode"` | `"ActiveDirectory"` |
| `"Graph"` → `"Enabled"` | `false` (Microsoft 365 lo conectas en el nivel 3) |
| Rutas `\\fs01.contoso.local\...` | `\\dc01.contoso.local\...` (en el laboratorio el DC hace de servidor de ficheros) |

Para lo último puedes usar este atajo:

```powershell
(Get-Content .\config\settings.json -Raw) -replace 'fs01\.contoso\.local', 'dc01.contoso.local' | Set-Content .\config\settings.json -Encoding UTF8
```

Todo lo demás (OUs `OU=Usuarios,DC=contoso,DC=local`, grupos `GG-*`, departamentos...) ya coincide con el dominio que has creado.

### 3.5 Preparar el dominio (OUs, grupos, carpetas)

El script `Initialize-TestDomain.ps1` crea todo lo que espera la configuración. Primero en simulacro:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\Initialize-TestDomain.ps1 -WhatIf
```

Si lo que muestra te cuadra, ejecútalo de verdad con los usuarios de ejemplo:

```powershell
.\scripts\Initialize-TestDomain.ps1 -WithSampleUsers
```

Esto crea:
- OUs `Usuarios` (con una por departamento), `Bajas` y `Grupos`.
- Todos los grupos `GG-*` de la configuración.
- `C:\Shares\Departamentos\<departamento>` compartida como `\\DC01\Departamentos`, y `C:\Shares\home` compartida como `\\DC01\home$`. Los permisos NTFS quedan cerrados (solo Administradores y SYSTEM), así se ve claramente lo que concede la herramienta.
- Los usuarios de ejemplo `jgarcia`, `aruiz` y `lmartinez`, **creados con la propia herramienta** (tu primera prueba real).

Puedes ejecutarlo las veces que quieras: solo crea lo que falta.

### 3.6 Probar

```powershell
.\scripts\Start-UI.ps1
```

La insignia de arriba ya no dice "LAB": dice **Active Directory**. Repite el recorrido de la sección 2.3 y comprueba el resultado con las herramientas de Windows:

| Qué comprobar | Cómo |
| --- | --- |
| El usuario está en su OU, con puesto, departamento y responsable | `dsa.msc` (Usuarios y equipos de AD) → *Ver → Características avanzadas* → pestañas *Organización* y *Editor de atributos* |
| Grupos | `Get-ADPrincipalGroupMembership jgarcial \| Select Name` |
| Fecha de caducidad (si pusiste "Fin de contrato") | `Get-ADUser jgarcial -Properties AccountExpirationDate` |
| Carpeta personal y permisos | `Get-Acl C:\Shares\home\jgarcial \| Format-List` o *Propiedades → Seguridad* |
| Permiso en la carpeta del departamento | `Get-Acl C:\Shares\Departamentos\Ventas \| Select -Expand Access` |
| La baja: deshabilitada, en `OU=Bajas`, sin grupos, con descripción | `Get-ADUser aruiz -Properties Description, MemberOf` |
| El bloqueo de privilegios | Ver sección 6, prueba 7 |

### 3.7 (Opcional) Un PC cliente para iniciar sesión como el empleado

En un controlador de dominio solo los administradores pueden iniciar sesión, así que para "ser" el empleado nuevo necesitas una segunda VM:

1. Descarga **Windows 11 Enterprise Evaluation** (Evaluation Center, 90 días) e instálala en otra VM (2 vCPU, 4 GB) conectada a la misma red que DC01.
2. En el cliente, pon como DNS la IP del DC (en el DC: `Get-NetIPAddress -AddressFamily IPv4`):
   ```powershell
   Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses <IP-del-DC>
   Add-Computer -DomainName contoso.local -Credential CONTOSO\Administrador -Restart
   ```
3. Inicia sesión como `CONTOSO\jgarcial` con la contraseña inicial: te obligará a cambiarla, tendrá la unidad `H:` y podrás comprobar a qué carpetas compartidas accede.

---

## 4. Nivel 3 — Conectar Microsoft 365 (opcional)

Necesitas un **tenant de pruebas**: una prueba gratuita de *Microsoft 365 Business Premium* (1 mes) o el *Microsoft 365 Developer Program* si cumples sus requisitos. No uses el tenant de tu empresa.

### 4.1 Sincronizar el AD del laboratorio con Entra ID

1. En el tenant, añade y verifica un dominio propio, o usa el `*.onmicrosoft.com`. Si usas `onmicrosoft.com`, pon ese sufijo en `Domain.UpnSuffix` del `settings.json` **antes** de crear usuarios.
2. En la VM descarga e instala **Microsoft Entra Connect Sync** (en un laboratorio puede ir en el propio DC). Configuración rápida + *Password Hash Sync*. Si quieres, limita la sincronización a la OU `Usuarios`.

### 4.2 Registrar la aplicación (permisos para la herramienta)

1. **Crear un certificado** (en la VM, PowerShell normal):
   ```powershell
   $cert = New-SelfSignedCertificate -Subject 'CN=Automate-AD' -CertStoreLocation Cert:\CurrentUser\My -KeySpec Signature -NotAfter (Get-Date).AddYears(1)
   Export-Certificate -Cert $cert -FilePath .\automate-ad.cer
   $cert.Thumbprint     # apúntalo
   ```
2. **Entra admin center** (entra.microsoft.com) → *Aplicaciones → Registros de aplicaciones → Nuevo registro*. Nombre `Automate-AD` → *Registrar*. Apunta el **Id. de aplicación (cliente)** y el **Id. de directorio (inquilino)**.
3. *Certificados y secretos → Certificados → Cargar* → `automate-ad.cer`.
4. *Permisos de API → Agregar → Microsoft Graph → **Permisos de aplicación***:
   `User.ReadWrite.All`, `LicenseAssignment.ReadWrite.All` y `Organization.Read.All`. Después pulsa **Conceder consentimiento de administrador**.

### 4.3 Configurar y probar

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
notepad .\config\settings.json
```

En la sección `"Graph"`: `"Enabled": true`, `"Auth": "Certificate"`, `TenantId`, `ClientId` y `CertificateThumbprint` con tus valores, `"DeltaSyncServer": "DC01"`. En cada departamento, `Licenses` con los SKU que tengas. Para verlos:

```powershell
Connect-MgGraph -TenantId <tenant> -ClientId <cliente> -CertificateThumbprint <huella> -NoWelcome
(Invoke-MgGraphRequest GET '/v1.0/subscribedSkus').value | ForEach-Object { $_.skuPartNumber }
```

Ahora un alta hará también: sincronización delta → espera a que el usuario aparezca en Entra ID → ubicación de uso `ES` → licencias. Si la sincronización tarda más que `SyncWaitSeconds`, el paso queda **Pendiente**. Reinténtalo con el botón *Reintentar licencias* o con `Invoke-LifecycleCloudProvisioning -Identity <usuario>`.

Una baja revocará las sesiones (`revokeSignInSessions`) y liberará las licencias.

---

## 5. Uso del día a día

| Quiero... | Comando |
| --- | --- |
| Abrir la interfaz web | `.\scripts\Start-UI.ps1` (otro puerto: `-Port 9000`) |
| Ver qué haría un alta | `Get-LifecycleOnboardingPlan -GivenName .. -Surname .. -Department .. -Title ..` |
| Dar de alta | `New-LifecycleUser ...` (añade `-WhatIf` para simular) |
| Altas masivas | `.\scripts\Invoke-BulkOnboarding.ps1 -CsvPath altas.csv` |
| Ver qué haría una baja | `Get-LifecycleOffboardingPlan -Identity usuario` |
| Dar de baja | `Disable-LifecycleUser -Identity usuario -Reason '...' -Ticket '...'` |
| Reintentar licencias | `Invoke-LifecycleCloudProvisioning -Identity usuario` |
| Buscar a alguien | `Find-LifecycleUser garcia` |
| Ver el historial | `Get-LifecycleAuditLog -Last 20` |
| Verificar que nadie ha tocado el log | `Test-LifecycleAuditLog` |

**Dónde queda todo:** `data/audit/reports/` (informes HTML y JSON) y `data/audit/audit-log.jsonl` (log encadenado). Esa carpeta tiene datos personales: no la subas a Git (ya está en `.gitignore`).

**Adaptarlo a tu empresa:** todo vive en `config/settings.json`: departamentos, OUs, grupos, carpetas, licencias y reglas por puesto. La tabla de claves está en el [README](../README.md#configuration).

---

## 6. Lista de pruebas (checklist)

Marca cada una cuando la hayas visto funcionar. Las pruebas 1 a 10 valen tanto en modo Lab como con AD real.

| # | Prueba | Resultado esperado | ✔ |
| --- | --- | --- | --- |
| 1 | Alta de `Juan García López` en Ventas | Cuenta `jgarcial` (porque `jgarcia` existe), OU Ventas, grupos GG-Todos/GG-Ventas/GG-CRM | ☐ |
| 2 | Alta con puesto `Jefe de ...` | Además entra en GG-Responsables | ☐ |
| 3 | Alta con puesto `Becario de ...` | Entra en GG-Becarios; su licencia es la de becarios, no la del departamento | ☐ |
| 4 | Alta con nombre en MAYÚSCULAS y tildes (`ÑUÑO PEÑA`) | Nombre mostrado "Ñuño Peña", cuenta `npena` | ☐ |
| 5 | Alta con "Fin de contrato" | La cuenta caduca al terminar ese día | ☐ |
| 6 | Alta con responsable inexistente o nº de empleado repetido | Plan bloqueado, no se crea nada, queda "Rechazada" en Auditoría | ☐ |
| 7 | **Bloqueo de privilegios**: en `settings.json` añade a una regla de puesto el grupo `Domain Admins` (o `Admins. del dominio` en un DC en español) e intenta un alta con ese puesto | "BLOQUEADO: ... grupo privilegiado", no se crea nada. **Deshaz el cambio después.** | ☐ |
| 8 | Baja de `aruiz` | Deshabilitada, en OU Bajas, sin grupos, descripción `BAJA fecha \| ticket \| motivo \| operador` | ☐ |
| 9 | Intentar dar de baja a `Administrator` | Rechazado (cuenta integrada) | ☐ |
| 10 | Editar una línea del log y verificar | "Cadena rota en la línea N" | ☐ |
| 11 | (AD + PC cliente, 3.7) Iniciar sesión con el usuario nuevo | Pide cambiar la contraseña; tiene la unidad `H:` | ☐ |
| 12 | (AD + PC cliente) Entrar en `\\DC01\Departamentos\Ventas` con un usuario de Marketing | Acceso denegado (sin cliente: `Get-Acl` muestra que no tiene permiso) | ☐ |
| 13 | (AD + PC cliente) Iniciar sesión con un usuario dado de baja | "Tu cuenta está deshabilitada" | ☐ |
| 14 | (M365) Alta con Graph | Usuario visible en Entra ID, ubicación ES, licencia asignada | ☐ |
| 15 | (M365) Baja con sesión abierta en office.com | La sesión se cierra en minutos; licencia liberada | ☐ |

---

## 7. Problemas frecuentes

| Mensaje / síntoma | Solución |
| --- | --- |
| *"...no se puede cargar porque la ejecución de scripts está deshabilitada"* | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` y `Get-ChildItem -Recurse \| Unblock-File` |
| *"Acceso denegado"* al abrir la web | Abre la URL **completa** con `?t=...` de la consola. Cada arranque genera un token nuevo. |
| *"No se pudo abrir el puerto 8787"* | Ya hay algo usando ese puerto (¿otra ventana con la UI abierta?): `.\scripts\Start-UI.ps1 -Port 9000` |
| *"Falta el módulo RSAT ActiveDirectory"* | En un DC ya está. En un PC: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` |
| *"La OU del departamento no existe"* / *"El grupo ... no existe"* | Ejecuta `.\scripts\Initialize-TestDomain.ps1`, o revisa los `DC=` de `settings.json` |
| *"...does not belong to this domain"* | Tu dominio no se llama `contoso.local`: cambia los `DC=contoso,DC=local` de `settings.json` por los tuyos |
| *"Configuración inválida: Graph.CertificateThumbprint es obligatorio"* | Pon `"Graph": { "Enabled": false }` hasta llegar al nivel 3 |
| Carpeta compartida: *"no existe o no es accesible"* | Las rutas `\\servidor\...` deben existir. ¿Cambiaste `fs01` por `dc01`? |
| Graph: *Insufficient privileges* / *Authorization_RequestDenied* | Falta *Conceder consentimiento de administrador* en los permisos de la app |
| Licencia: *invalid usage location* | Revisa `Graph.UsageLocation` (código de país de 2 letras, p. ej. `ES`) |
| El paso de licencias queda **Pendiente** | Entra Connect no ha sincronizado aún: `Invoke-LifecycleCloudProvisioning -Identity usuario`, o sube `SyncWaitSeconds` |
| Tildes rotas en Windows PowerShell 5.1 | No edites los `.ps1` con un editor que quite el BOM UTF-8; usa VS Code o el Bloc de notas moderno |

---

## 8. Limpiar / desinstalar

- **Modo Lab:** borra la carpeta `data/` o ejecuta `Reset-LifecycleLab -IncludeAudit`.
- **Laboratorio AD:** lo más rápido es volver al checkpoint de la VM. A mano: borra las OUs `Usuarios`, `Bajas` y `Grupos` (el script las crea sin protección contra borrado), los recursos compartidos (`Remove-SmbShare Departamentos, 'home$'`) y `C:\Shares`.
- **Microsoft 365:** borra el registro de aplicación `Automate-AD` y el certificado (`Cert:\CurrentUser\My`).
- **La herramienta:** borra la carpeta. No instala nada en el sistema.
