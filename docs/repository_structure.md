# Repository Structure

## Top-level modules

- `mobile/` Flutter application (Android, iOS, Web, Desktop, shared Dart code)
- `firmware/stm32/` STM32 firmware source and CubeMX project
- `firmware/esp8266/` ESP8266 gateway firmware
- `backend/functions/` Firebase Cloud Functions source

## Flutter app layout (`mobile/lib`)

- `screens/auth/` authentication and startup flow screens
- `screens/monitoring/` dashboard, charts, graph, and sensor monitoring screens
- `screens/settings/` settings and notification management screens
- `screens/notifications/` push and local notification services
- `screens/common/` shared UI elements used by multiple screens
- `screens/admin/` admin-only screen(s)
