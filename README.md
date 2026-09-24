# Despliegue de DRIM PPME

Este paquete usa el front de la rama `PPME` de DRIM (commit `cf262973ce9e87854eb3a50b0e6ebc02368ee618`). `DRIMFront.zip` contiene el código fuente que Compose construye en el servidor. El broker MQTT se configura con `mosquitto/mosquitto.conf` y conserva sus datos en el volumen `drim-mqtt-data`.

## Publicar las imágenes de las APIs

Las APIs no se incluyen en este repositorio: hay que construirlas desde la **misma revisión PPME** y publicar sus imágenes antes de ejecutar `deploy.sh` o `update.sh`. Desde la raíz del checkout de DRIM:

```bash
docker build -f DRIMBack/Dockerfile -t datawaresit/drim-back:ppme .
docker build -f PM_Printer_API/Dockerfile -t datawaresit/drim-pm:ppme .
docker push datawaresit/drim-back:ppme
docker push datawaresit/drim-pm:ppme
```

El Dockerfile de DRIMBack copia también `DRIM.Modules.Identification.Contracts`, que no existe en el build de `main`. Los healthchecks de los tres Dockerfiles deben consultar `localhost:8080` dentro del contenedor; esos ajustes están hechos en el checkout PPME de este workspace y en el ZIP del front.

Se pueden usar imágenes de otro registro mediante `DRIM_BACK_IMAGE` y `DRIM_PM_IMAGE` en `.env`. Las mismas variables se usan al arrancar las APIs y al ejecutar migraciones. Mantén ambas imágenes y el ZIP del front en la misma revisión de PPME; evita reutilizar un tag `ppme` de una compilación anterior.

## Instalar o actualizar

Configura `.env` con `MSSQL_SA_PASSWORD`, `DB_PASSWORD`, `FRONT_URL`, `DRIM_API_URL` y `PM_API_URL`. Las URL públicas deben ser accesibles desde el navegador de los usuarios. Después ejecuta `./scripts/deploy.sh` para una instalación nueva o `./scripts/update.sh` para actualizar. Los scripts descargan las imágenes antes de migrar las bases de datos.

El servicio MQTT publica el puerto `1883`. La configuración incluida permite conexiones anónimas, igual que el compose de PPME; ajusta `mosquitto.conf` y el acceso de red según el entorno de despliegue.
