# Minecraft VPS Assistant

Asistente Bash para montar un servidor de Minecraft en un VPS Ubuntu/Debian.

## Que hace

- Muestra un menu principal para instalar un servidor nuevo o editar uno existente.
- Instala Java y herramientas necesarias con `apt`.
- Crea un usuario Linux dedicado para el servidor.
- Descarga `server.jar` para Vanilla, Paper o Fabric.
- Permite Forge/NeoForge usando una URL directa del instalador o jar.
- Configura `eula.txt`, `server.properties`, `start.sh` y un servicio `systemd`.
- Permite elegir modo premium (`online-mode=true`) o no premium (`online-mode=false`).
- Puede abrir el puerto en UFW.
- Puede descargar mods/plugins desde una lista de enlaces.
- Detecta instancias existentes en `/opt/minecraft` y permite cambiar modo de juego, dificultad, PvP, whitelist, puerto, MOTD, RAM, mobs, vuelo y mas.
- Permite crear una instancia Forge/NeoForge sin pegar el jar en ese momento, para instalarlo despues.
- Permite arrancar, parar, reiniciar, revisar estado y ver logs del servicio.

## Uso rapido

En el VPS:

```bash
chmod +x install-minecraft-server.sh
sudo ./install-minecraft-server.sh
```

El asistente te preguntara si quieres:

```txt
1) instalar nuevo servidor
2) editar instancia existente
3) salir
```

## Editar instancias existentes

El asistente busca servidores en:

```txt
/opt/minecraft/<nombre-del-servidor>/server.properties
```

Desde el menu de edicion puedes cambiar:

- Modo de juego: survival, creative, adventure o spectator.
- Dificultad.
- Premium/no premium (`online-mode`).
- PvP y command blocks.
- MOTD, jugadores maximos, puerto, view distance y simulation distance.
- Whitelist, vuelo, animales y monstruos.
- RAM usada por `start.sh`.
- Instalar o reemplazar `server.jar` despues de crear la instancia.
- Mods/plugins desde un archivo de enlaces.
- Servicio `systemd`: start, stop, restart, status y logs.

Cuando cambias propiedades, el script crea un backup de `server.properties` antes de tocarlo.

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
