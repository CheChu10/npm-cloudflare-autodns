# Cloudflare Auto-DNS for Nginx Proxy Manager

[English](#english) | [Español](#español)

---

<a name="english"></a>
## English

A robust Bash script that monitors Nginx Proxy Manager configuration files and automatically manages Cloudflare DNS CNAME records. It's designed to run as a secure, reliable systemd daemon.

### Key Features

1.  **Guaranteed Singleton (Atomicity)**: Uses `flock` on a file descriptor to ensure only one instance of the script can run at a time. It's inherently atomic and safe against multiple executions, and provides a clear error message if a second instance is attempted.
2.  **Race Condition Prevention (Per-File Locking)**: Employs an atomic `mkdir` lock system for each configuration file. This prevents bursts of `inotify` events from launching duplicate processing jobs for the same file.
3.  **Intelligent Event Handling (Debouncing)**: Ignores redundant events while a file is being processed. It intelligently distinguishes between a real deletion and an atomic save (delete + recreate) via a strategic pause, preventing unnecessary DNS cleanups.
4.  **Idempotency and Efficiency**: Calculates a hash of the domains within each file. It only contacts the Cloudflare API if the relevant content has actually changed.
5.  **Secure by Design**: The Cloudflare API token (`CF_API_TOKEN`) is loaded exclusively from an environment variable, keeping secrets out of the code. It's designed to be securely injected by the `systemd` service.

### Prerequisites

*   `bash` (v4.0+)
*   `curl`
*   `jq`
*   `inotify-tools` (`inotifywait`)
*   `util-linux` (`flock`)

On Debian/Ubuntu, you can install them with:
```bash
sudo apt-get update && sudo apt-get install -y curl jq inotify-tools util-linux
```

### Installation

1.  **Place the Script**
    Clone this repository or download the `cf_autodns.sh` script to a suitable location. A good practice is to use a dedicated directory for your user.
    ```bash
    mkdir -p ~/bin
    cp cf_autodns.sh ~/bin/cf_autodns.sh
    chmod +x ~/bin/cf_autodns.sh
    ```

2.  **Create Directories**
    The script needs a base directory to store its state (hashes and locks). The user running the script must own this directory.
    ```bash
    # The path must match the BASE_DIR variable in the script.
    mkdir -p /opt/appdata/npm/cf_autodns
    sudo chown your_user:your_group /opt/appdata/npm/cf_autodns
    ```

### Configuration

Configuration is managed entirely through environment variables, making the script portable and keeping settings separate from the code. The recommended way to set these is through the `systemd` service file.

1.  **Systemd Service**
    To run the script as a reliable daemon, create a `systemd` service file at `/etc/systemd/system/cf_autodns.service`. An example is provided in this repository (`cf_autodns.service`).

    You **must** configure the following environment variables within the service file:
    *   `CF_API_TOKEN`: Your Cloudflare API token.
    *   `BASE_DIR`: The script's working directory. It's used to store state files, such as domain hashes and temporary lock files. The user running the script must have write permissions here.
    *   `WATCH_DIR`: The directory where Nginx Proxy Manager stores its proxy host configuration files (`*.conf`). This script is compatible with any setup, including Docker volumes.
    *   `DEBUG_MODE`: (Optional) Set to `true` for verbose logging.

    After creating the file, secure it, as it contains a secret:
    ```bash
    sudo chmod 600 /etc/systemd/system/cf_autodns.service
    ```

### Usage

Manage the service with `systemctl`:
*   **Start the service:** `sudo systemctl start cf_autodns.service`
*   **Enable on boot:** `sudo systemctl enable cf_autodns.service`
*   **Check status:** `sudo systemctl status cf_autodns.service`
*   **View logs in real-time:** `sudo journalctl -u cf_autodns.service -f`

---

<a name="español"></a>
## Español

Un script de Bash robusto que monitoriza los archivos de configuración de Nginx Proxy Manager y gestiona automáticamente los registros CNAME de Cloudflare. Está diseñado para funcionar como un demonio de `systemd` seguro y fiable.

### Características Clave

1.  **Singleton Garantizado (Atomicidad)**: Usa `flock` sobre un descriptor de fichero para asegurar que solo una instancia del script pueda ejecutarse a la vez. Es inherentemente atómico y seguro contra ejecuciones múltiples, y proporciona un mensaje de error claro si se intenta ejecutar una segunda instancia.
2.  **Prevención de Condiciones de Carrera (Bloqueo por Fichero)**: Emplea un sistema de bloqueo atómico con `mkdir` para cada archivo de configuración. Esto previene que ráfagas de eventos de `inotify` lancen procesos duplicados para el mismo fichero.
3.  **Manejo Inteligente de Eventos (Debouncing)**: Ignora eventos redundantes mientras un fichero está siendo procesado. Distingue de forma inteligente entre un borrado real y un guardado atómico (borrar + recrear) mediante una pausa estratégica, evitando limpiezas de DNS innecesarias.
4.  **Idempotencia y Eficiencia**: Calcula un hash de los dominios de cada fichero. Solo contacta con la API de Cloudflare si el contenido relevante ha cambiado realmente.
5.  **Seguro por Diseño**: El token de la API de Cloudflare (`CF_API_TOKEN`) se carga exclusivamente desde una variable de entorno, manteniendo los secretos fuera del código. Está diseñado para ser inyectado de forma segura por el servicio de `systemd`.

### Prerrequisitos

*   `bash` (v4.0+)
*   `curl`
*   `jq`
*   `inotify-tools` (`inotifywait`)
*   `util-linux` (`flock`)

En Debian/Ubuntu, puedes instalarlos con:
```bash
sudo apt-get update && sudo apt-get install -y curl jq inotify-tools util-linux
```

### Instalación

1.  **Colocar el Script**
    Clona este repositorio o descarga el script `cf_autodns.sh` en una ubicación adecuada. Una buena práctica es usar un directorio dedicado para tu usuario.
    ```bash
    mkdir -p ~/bin
    cp cf_autodns.sh ~/bin/cf_autodns.sh
    chmod +x ~/bin/cf_autodns.sh
    ```

2.  **Crear Directorios**
    El script necesita un directorio base para almacenar su estado (hashes y bloqueos). El usuario que ejecuta el script debe ser el propietario de este directorio.
    ```bash
    # La ruta debe coincidir con la variable BASE_DIR en el script.
    mkdir -p /opt/appdata/npm/cf_autodns
    sudo chown tu_usuario:tu_grupo /opt/appdata/npm/cf_autodns
    ```

### Configuración

La configuración se gestiona completamente a través de variables de entorno, lo que hace que el script sea portable y mantiene los ajustes separados del código. La forma recomendada de establecerlas es a través del archivo de servicio de `systemd`.

1.  **Servicio de Systemd**
    Para ejecutar el script como un demonio fiable, crea un archivo de servicio de `systemd` en `/etc/systemd/system/cf_autodns.service`. En este repositorio se proporciona un ejemplo (`cf_autodns.service`).

    **Debes** configurar las siguientes variables de entorno dentro del archivo de servicio:
    *   `CF_API_TOKEN`: Tu token de la API de Cloudflare.
    *   `BASE_DIR`: El directorio de trabajo del script. Se utiliza para guardar archivos de estado, como los hashes de los dominios y los ficheros de bloqueo temporales. El usuario que ejecuta el script debe tener permisos de escritura aquí.
    *   `WATCH_DIR`: El directorio donde Nginx Proxy Manager guarda sus ficheros de configuración de proxy hosts (`*.conf`). El script es compatible con cualquier tipo de instalación, incluidas las que usan volúmenes de Docker.
    *   `DEBUG_MODE`: (Opcional) Establécelo a `true` para un registro detallado.

    Después de crear el archivo, asegúralo, ya que contiene un secreto:
    ```bash
    sudo chmod 600 /etc/systemd/system/cf_autodns.service
    ```

### Uso

Gestiona el servicio con `systemctl`:
*   **Iniciar el servicio:** `sudo systemctl start cf_autodns.service`
*   **Habilitar en el arranque:** `sudo systemctl enable cf_autodns.service`
*   **Comprobar estado:** `sudo systemctl status cf_autodns.service`
*   **Ver logs en tiempo real:** `sudo journalctl -u cf_autodns.service -f`
