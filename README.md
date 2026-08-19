# Water Monitoring System

This repository contains the mobile application and embedded firmware used by the water monitoring project.

## Repository structure

- `lib/`, `android/`, `ios/`, `web/`, `windows/`, `linux/`, `macos/`  
  Flutter mobile/web/desktop application.
- `firmware/stm32/`  
  STM32 firmware sources and project files (`main.c`, `adc_test.ioc`).
- `firmware/esp8266/`  
  ESP8266 gateway firmware (`esp8266_gateway.ino`).
- `functions/`  
  Firebase Cloud Functions backend.
