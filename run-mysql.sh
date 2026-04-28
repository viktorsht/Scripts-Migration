#!/bin/bash

CONTAINER_NAME=$1
MYSQL_ROOT_PASSWORD=$2
MYSQL_DATABASE=$3
MYSQL_PORT=$4

if [ -z "$CONTAINER_NAME" ] || [ -z "$MYSQL_ROOT_PASSWORD" ] || [ -z "$MYSQL_DATABASE" ] || [ -z "$MYSQL_PORT" ]; then
  echo "Uso: ./run-mysql.sh <container_name> <root_password> <database> <port>"
  exit 1
fi

VOLUME_NAME="$CONTAINER_NAME-data"

echo "Verificando volume..."
docker volume inspect $VOLUME_NAME >/dev/null 2>&1

if [ $? -eq 0 ]; then
  echo "⚠️ Volume já existe: $VOLUME_NAME"
  echo "Se tiver problemas, remova com:"
  echo "docker volume rm $VOLUME_NAME"
fi

echo "Subindo MySQL 8..."
echo "Container: $CONTAINER_NAME"
echo "Database: $MYSQL_DATABASE"
echo "Porta: $MYSQL_PORT"

docker run -d \
  --name $CONTAINER_NAME \
  -e MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD \
  -e MYSQL_DATABASE=$MYSQL_DATABASE \
  -p $MYSQL_PORT:3306 \
  -v $VOLUME_NAME:/var/lib/mysql \
  mysql:8.0

echo "MySQL iniciado 🚀"