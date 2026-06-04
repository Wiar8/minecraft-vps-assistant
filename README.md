# Minecraft VPS Assistant

Asistente Bash para montar un servidor de Minecraft en un VPS Ubuntu/Debian.

## Que hace

- Instala Java y herramientas necesarias con `apt`.
- Crea un usuario Linux dedicado para el servidor.
- Descarga `server.jar` para Vanilla, Paper o Fabric.
- Permite Forge/NeoForge usando una URL directa del instalador o jar.
- Configura `eula.txt`, `server.properties`, `start.sh` y un servicio `systemd`.
- Permite elegir modo premium (`online-mode=true`) o no premium (`online-mode=false`).
- Puede abrir el puerto en UFW.
- Puede descargar mods/plugins desde una lista de enlaces.

## Uso rapido

En el VPS:

```bash
chmod +x install-minecraft-server.sh
sudo ./install-minecraft-server.sh
```

## Mods y plugins

Puedes crear un archivo `mods.txt` con un enlace por linea:

```txt
https://modrinth.com/mod/fabric-api
https://cdn.example.com/mods/algun-mod.jar
https://www.curseforge.com/minecraft/mc-mods/example-mod
```

### CurseForge

La autodescarga desde CurseForge no siempre es posible solo con el enlace publico. CurseForge protege parte de sus descargas y su API oficial requiere una clave.

Para mejorar la compatibilidad, exporta una API key antes de ejecutar el asistente:

```bash
export CF_API_KEY="tu_api_key"
sudo -E ./install-minecraft-server.sh
```

Sin `CF_API_KEY`, el script intenta enlaces directos a `.jar` o `.zip`, pero los enlaces normales de CurseForge pueden fallar. Esto es una limitacion real de CurseForge, no del VPS.

## Comandos utiles despues de instalar

```bash
sudo systemctl start minecraft-survival
sudo systemctl stop minecraft-survival
sudo systemctl status minecraft-survival
sudo journalctl -u minecraft-survival -f
```

El nombre exacto del servicio depende del nombre interno que elijas durante la instalacion.

## Nota de seguridad

El modo no premium usa `online-mode=false`. Funciona para servidores privados, pero reduce la verificacion de identidad de jugadores. Si lo usas, activa whitelist, permisos y backups.
