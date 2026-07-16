# syntax=docker/dockerfile:1

FROM eclipse-temurin:21-jdk-alpine AS builder
WORKDIR /build
COPY pom.xml .
COPY device-report-service/pom.xml device-report-service/
COPY command-dispatch-service/pom.xml command-dispatch-service/
COPY device-report-consumer/pom.xml device-report-consumer/
# 仅下载 device-report-service 依赖（利用 Docker layer cache）
RUN apk add --no-cache maven && \
    mvn -B -pl device-report-service -am dependency:go-offline -DskipTests

COPY device-report-service/src device-report-service/src
COPY command-dispatch-service/src command-dispatch-service/src
COPY device-report-consumer/src device-report-consumer/src
RUN mvn -B -pl device-report-service -am package -DskipTests

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
# logback 写 ${logging.file.path:-log} → /app/log；需在切到非 root 前建好目录
RUN addgroup -S spring && adduser -S spring -G spring \
    && mkdir -p /app/log \
    && chown -R spring:spring /app
USER spring:spring
COPY --from=builder --chown=spring:spring /build/device-report-service/target/device-report-service-*.jar app.jar

ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"
ENV SPRING_PROFILES_ACTIVE=k8s

EXPOSE 8765
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]