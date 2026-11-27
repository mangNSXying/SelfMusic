package com.selfmusic.backend;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
public class SelfMusicApplication {
    public static void main(String[] args) {
        SpringApplication.run(SelfMusicApplication.class, args);
    }
}
