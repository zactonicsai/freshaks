#!/bin/sh
# Starts the Java app. JAVA_HOME is set by the Red Hat OpenJDK image.
exec "${JAVA_HOME:-/usr/lib/jvm/jre}/bin/java" \
  -XX:MaxRAMPercentage=70 \
  -Djava.security.krb5.conf="${KRB5_CONF:-/etc/fipsdemo/krb5/krb5.conf}" \
  -cp /opt/app/classes demo.Main
