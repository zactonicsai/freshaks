package com.example.demo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Start class of the demo application. The same program runs twice in the
 * cluster: as "Portal" (app1) and as "Reports" (app2). Name, look and OIDC
 * client come from environment variables that the Helm chart sets.
 */
@SpringBootApplication
public class DemoApplication {

    public static void main(String[] args) {
        SpringApplication.run(DemoApplication.class, args);
    }
}
