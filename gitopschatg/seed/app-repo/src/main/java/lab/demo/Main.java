package lab.demo;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;

public class Main {
    public static String message() {
        return "Hello from the GitOps demo app";
    }

    private static void write(HttpExchange exchange, int code, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(code, bytes.length);
        exchange.getResponseBody().write(bytes);
        exchange.close();
    }

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/", exchange -> write(exchange, 200,
            "{\"message\":\"" + message() + "\",\"time\":\"" + Instant.now() + "\"}"));
        server.createContext("/health", exchange -> write(exchange, 200, "{\"status\":\"UP\"}"));
        server.setExecutor(null);
        server.start();
        System.out.println("demo-app listening on port " + port);
    }
}
