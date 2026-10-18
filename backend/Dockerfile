FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /app
COPY pom.xml .
# Maven 走阿里云镜像（CN 直连 central 只有百 KB/s 级）；换源改 settings.xml。
COPY settings.xml /root/.m2/settings.xml
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -DskipTests -B

FROM eclipse-temurin:21-jre
# 阶段6：无状态转码代理需要 ffmpeg 二进制（dev 镜像已有，此处补齐 prod）。
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
# 复用基镜像自带的 ubuntu 用户（UID 1000，与 Dockerfile.dev / compose user 对齐）：
# temurin 已占用 UID 1000，自建 app 用户会报 "UID 1000 is not unique" 导致构建失败。
WORKDIR /app
RUN chown -R ubuntu:ubuntu /app
USER ubuntu
COPY --from=builder --chown=ubuntu:ubuntu /app/target/selfmusic-backend.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
