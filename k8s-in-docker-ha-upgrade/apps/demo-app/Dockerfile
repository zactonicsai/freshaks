# Dockerfile of the demo application. Two stages: the first one builds the
# jar, the second one is the small image that runs in the cluster.
# The same image is deployed twice (as "Portal" and as "Reports").

# ---- Stage 1: build -----------------------------------------------------------
# Maven 3.9 with a Java 21 JDK.
FROM maven:3.9-eclipse-temurin-21 AS build
# Work in /src inside the build container.
WORKDIR /src
# Copy the build file and the sources.
COPY pom.xml .
COPY src ./src
# Build the runnable jar (target/app.jar). --batch-mode and
# --no-transfer-progress keep the log short; tests are skipped (there are none).
RUN mvn --batch-mode --no-transfer-progress -DskipTests package

# ---- Stage 2: run -------------------------------------------------------------
# Only a Java 21 runtime: no compiler, no Maven, no sources.
FROM eclipse-temurin:21-jre
# The version shown in the web page and in /api/info. It is passed in with
#   docker build --build-arg APP_VERSION=2.0.0 ...
# so "version 1.0.0" and "version 2.0.0" are built from the same sources.
ARG APP_VERSION=dev
# Make it visible to the running application as an environment variable.
ENV APP_VERSION=${APP_VERSION}
# The application lives in /app.
WORKDIR /app
# Copy the jar from the build stage.
COPY --from=build /src/target/app.jar /app/app.jar
# Run as an unprivileged user. A numeric id lets Kubernetes verify
# "runAsNonRoot" without looking into /etc/passwd.
USER 10001:10001
# The port the embedded Tomcat listens on.
EXPOSE 8080
# Start the application. Memory settings come from JAVA_TOOL_OPTIONS, which
# the Helm chart sets.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
