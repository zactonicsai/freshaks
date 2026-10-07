# ---------- Stage 1: build the app ----------
# This first image has Java + Maven. It turns our source code into one .jar file.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
COPY src ./src
RUN mvn -B -q package -DskipTests

# ---------- Stage 2: run the app ----------
# This second image is smaller. It has only what is needed to RUN Java.
# The build tools from stage 1 are left behind (smaller = safer).
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/demo-app.jar /app/app.jar
# Do not run as "root" (the all-powerful user). Use a plain numbered user.
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
