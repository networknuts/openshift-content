#!/bin/bash

openssl genrsa -out app.key 2048
openssl req -new -key app.key -out app.csr -config app.config
openssl req -x509 -sha256 -nodes -new -key app.key -out app.crt -config app.config
openssl x509 -sha256 -CAcreateserial -req -days 365 -in app.csr -extfile app.config -CA app.crt -CAkey app.key -out main.crt

echo "Certificate created successfully!"
