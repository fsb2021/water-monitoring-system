#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <FirebaseESP8266.h>
#include <SoftwareSerial.h>

// ================= CONFIG =================
const char* WIFI_SSID     = "wifi-name";
const char* WIFI_PASSWORD = "wifi pasword";

#define FIREBASE_HOST "fire base project"
#define FIREBASE_AUTH "token"

// ================= PINOUT =================
// ESP8266 NodeMCU: D5 = GPIO14 = RX from STM32 TX
//                  D6 = GPIO12 = TX to STM32 RX
SoftwareSerial mySerial(14, 12);

// ================= OBJECTS =================
FirebaseData firebaseData;
FirebaseConfig config;
FirebaseAuth auth;

// SERVEUR TCP
// =====================================================
WiFiServer gsmServer(80);
bool gsmServerStarted = false;
// ================= WIFI =================
// =====================================================
// CONFIG GSM
// =====================================================
#define MAX_GSM_NUMBERS 5

String gsmMode = "ON";

String gsmNumbers[MAX_GSM_NUMBERS];

int gsmNumberCount = 0;
int lastGsmOutputState = -1; // -1 inconnu, 0 OFF, 1 ON


// =====================================================
// VERIFIER NUMERO
// =====================================================
bool isValidPhoneNumber(String number)
{
    number.trim();

    if (number.length() < 9 || number.length() > 16)
    {
        return false;
    }

    if (number.charAt(0) != '+')
    {
        return false;
    }

    for (unsigned int i = 1; i < number.length(); i++)
    {
        if (!isDigit(number.charAt(i)))
        {
            return false;
        }
    }

    return true;
}


// =====================================================
// PARSER LA LISTE
// Exemple :
// ["+21650610318","+21622123456"]
// =====================================================
bool parsePhoneList(String data)
{
    data.trim();

    gsmNumberCount = 0;

    // Effacer ancienne liste
    for (int i = 0; i < MAX_GSM_NUMBERS; i++)
    {
        gsmNumbers[i] = "";
    }

    // Vérification []
    if (!data.startsWith("[") || !data.endsWith("]"))
    {
        Serial.println("Format liste invalide");
        return false;
    }

    int position = 0;

    while (gsmNumberCount < MAX_GSM_NUMBERS)
    {
        // Chercher premier "
        int quoteStart = data.indexOf('"', position);

        if (quoteStart == -1)
        {
            break;
        }

        // Chercher deuxième "
        int quoteEnd = data.indexOf('"', quoteStart + 1);

        if (quoteEnd == -1)
        {
            return false;
        }

        // Extraire numéro
        String number = data.substring(
            quoteStart + 1,
            quoteEnd
        );

        number.trim();

        // Vérifier
        if (isValidPhoneNumber(number))
        {
            gsmNumbers[gsmNumberCount] = number;

            gsmNumberCount++;
        }
        else
        {
            Serial.print("Numero invalide : ");
            Serial.println(number);
        }

        position = quoteEnd + 1;
    }

    return true;
}
// =====================================================
// AFFICHER CONFIGURATION
// =====================================================
void printGSMConfiguration()
{
    Serial.println();
    Serial.println("============================");
    Serial.println("CONFIGURATION GSM");
    Serial.println("============================");

    Serial.print("Mode : ");
    Serial.println(gsmMode);

    Serial.print("Nombre : ");
    Serial.println(gsmNumberCount);

    for (int i = 0; i < gsmNumberCount; i++)
    {
        Serial.print("Numero ");
        Serial.print(i);
        Serial.print(" : ");
        Serial.println(gsmNumbers[i]);
    }

    Serial.println("============================");
}


// =====================================================
// ETAT GSM EFFECTIF POUR LE STM32
// =====================================================
bool isGSMEnabledNow()
{
    if (gsmMode == "ON")
    {
        return true;
    }

    if (gsmMode == "OFF")
    {
        return false;
    }

    // BACKUP : GSM actif seulement si le Wi-Fi est perdu.
    if (gsmMode == "BACKUP")
    {
        return WiFi.status() != WL_CONNECTED;
    }

    return false;
}


// =====================================================
// ENVOYER UNIQUEMENT L'ETAT GSM AU STM32
// =====================================================
void updateGSMStateToSTM32(bool forceSend = false)
{
    int newState = isGSMEnabledNow() ? 1 : 0;

    if (!forceSend && newState == lastGsmOutputState)
    {
        return;
    }

    lastGsmOutputState = newState;

    if (newState == 1)
    {
        mySerial.println("gsm=1");
        Serial.println("STM32 <- gsm=1");
    }
    else
    {
        mySerial.println("gsm=0");
        Serial.println("STM32 <- gsm=0");
    }
}


// =====================================================
// ENVOYER CONFIGURATION COMPLETE AU STM32
// =====================================================
void sendGSMConfigurationToSTM32()
{
    // 1) Etat GSM effectif
    updateGSMStateToSTM32(true);
    delay(20);

    // 2) Nombre de numeros
    mySerial.print("GSM_COUNT:");
    mySerial.println(gsmNumberCount);
    delay(20);

    // 3) Numeros
    for (int i = 0; i < gsmNumberCount; i++)
    {
        mySerial.print("GSM_NUM:");
        mySerial.print(i);
        mySerial.print(":");
        mySerial.println(gsmNumbers[i]);
        delay(20);
    }
}


// =====================================================
// RECEVOIR CONFIGURATION DEPUIS PYTHON
// Protocole TCP attendu :
// Ligne 1 : GSM_MODE:ON / OFF / BACKUP
// Ligne 2 : ["+21650610318","+21694807898"]
// =====================================================
void handleGSMServer()
{
    WiFiClient client = gsmServer.available();

    if (!client)
    {
        return;
    }

    Serial.println();
    Serial.println("Client Python connecté");

    client.setTimeout(1500);

    // -------------------------
    // Ligne 1 : MODE
    // -------------------------
    String modeLine = client.readStringUntil('\n');
    modeLine.trim();

    Serial.print("Recu MODE : ");
    Serial.println(modeLine);

    // -------------------------
    // Ligne 2 : LISTE JSON
    // -------------------------
    String listLine = client.readStringUntil('\n');
    listLine.trim();

    Serial.print("Recu LISTE : ");
    Serial.println(listLine);

    // -------------------------
    // Traiter le mode
    // -------------------------
    bool modeOK = false;
    String newMode = "";

    if (modeLine.startsWith("GSM_MODE:"))
    {
        newMode = modeLine.substring(String("GSM_MODE:").length());
        newMode.trim();
        newMode.toUpperCase();

        if (newMode == "ON" ||
            newMode == "OFF" ||
            newMode == "BACKUP")
        {
            modeOK = true;
        }
    }

    // -------------------------
    // Traiter la liste
    // -------------------------
    bool listOK = parsePhoneList(listLine);

    // -------------------------
    // Appliquer si tout est OK
    // -------------------------
    if (modeOK && listOK)
    {
        gsmMode = newMode;

        Serial.println("Configuration GSM valide");
        printGSMConfiguration();

        sendGSMConfigurationToSTM32();

        // Python n'est pas obligé de lire cette réponse.
        client.println("OK");
    }
    else
    {
        Serial.println("ERREUR configuration GSM");

        if (!modeOK)
        {
            Serial.println("Mode GSM invalide");
        }

        if (!listOK)
        {
            Serial.println("Liste GSM invalide");
        }

        client.println("ERROR");
    }

    client.stop();
    Serial.println("Client Python déconnecté");
}
// ================= GLOBAL VARIABLES =================
String rxLine = "";

int lastECDelay   = -1;
int lastPhDelay   = -1;
int lastTempDelay = -1;
int lastTurbDelay = -1;

// ================= WIFI =================
void connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Connecting to WiFi");

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");

    if (millis() - start > 30000) {
      Serial.println("\n❌ WiFi timeout!");
      return;
    }
  }

  Serial.println("\n✅ WiFi Connected!");
  Serial.println("IP: " + WiFi.localIP().toString());
}

// ================= SERVEUR TCP GSM =================
// Demarre le serveur uniquement quand le Wi-Fi est disponible.
// Le port utilise par Python doit egalement etre 80.
void startGSMServerIfNeeded()
{
  if (WiFi.status() != WL_CONNECTED || gsmServerStarted)
  {
    return;
  }

  gsmServer.begin();
  gsmServerStarted = true;

  Serial.println("Serveur TCP GSM demarre sur le port 80");
  Serial.println("Python doit se connecter a : " +
                 WiFi.localIP().toString() + ":80");
}

// ================= FIREBASE SEND =================
void sendSensorToFirebase(const String& path, float value, const char* timeStr, const char* dateStr) {
  if (!Firebase.ready()) {
    Serial.println("⚠️ Firebase not ready, value not sent: " + path);
    return;
  }

  FirebaseJson json;
  json.set("value", value);
  json.set("time", timeStr);
  json.set("date", dateStr);

  if (Firebase.updateNode(firebaseData, path, json)) {
    Serial.println("✅ Sent to: " + path + " value=" + String(value, 2));
  } else {
    Serial.println("❌ Firebase Error on " + path + ": " + firebaseData.errorReason());
  }
}

// ================= SETTINGS FROM FIREBASE =================
void handleSettingsUpdate() {
  if (!Firebase.ready()) return;

  if (Firebase.getJSON(firebaseData, "/settings/sensor_delays")) {
    FirebaseJson &json = firebaseData.jsonObject();
    FirebaseJsonData data;

    json.get(data, "conductivity");
    if (data.success && data.intValue != lastECDelay) {
      lastECDelay = data.intValue;
      mySerial.print("SET_EC_DELAY:");
      mySerial.println(lastECDelay);
      Serial.printf("📢 Sent to STM32: New EC Delay = %d\n", lastECDelay);
    }

    json.get(data, "ph");
    if (data.success && data.intValue != lastPhDelay) {
      lastPhDelay = data.intValue;
      mySerial.print("SET_PH_DELAY:");
      mySerial.println(lastPhDelay);
      Serial.printf("📢 Sent to STM32: New pH Delay = %d\n", lastPhDelay);
    }

    json.get(data, "temperature");
    if (data.success && data.intValue != lastTempDelay) {
      lastTempDelay = data.intValue;
      mySerial.print("SET_TEMP_DELAY:");
      mySerial.println(lastTempDelay);
      Serial.printf("📢 Sent to STM32: New Temp Delay = %d\n", lastTempDelay);
    }

    json.get(data, "turbidity");
    if (data.success && data.intValue != lastTurbDelay) {
      lastTurbDelay = data.intValue;
      mySerial.print("SET_TURB_DELAY:");
      mySerial.println(lastTurbDelay);
      Serial.printf("📢 Sent to STM32: New Turb Delay = %d\n", lastTurbDelay);
    }
  } else {
    Serial.println("⚠️ Settings read error: " + firebaseData.errorReason());
  }
}

// ================= SERIAL READ =================
bool readLine(String &out) {
  while (mySerial.available()) {
    char c = mySerial.read();

    if (c == '\n' || c == '\r') {
      rxLine.trim();

      if (rxLine.length() > 3) {
        out = rxLine;
        rxLine = "";
        return true;
      }

      rxLine = "";
    } else {
      rxLine += c;

      if (rxLine.length() > 250) {
        Serial.println("⚠️ RX buffer too long, clearing: " + rxLine);
        rxLine = "";
      }
    }
  }

  return false;
}

// ================= UTILITIES =================
void extractTimeDate(const String& line, char* timeStr, char* dateStr) {
  int hh = 0, mm = 0;
  int dd = 0, mo = 0, yy = 0;

  int timeIndex = line.lastIndexOf("Time:");
  if (timeIndex >= 0) {
    sscanf(line.c_str() + timeIndex, "Time: %d:%d", &hh, &mm);
  } else {
    timeIndex = line.lastIndexOf("Time=");
    if (timeIndex >= 0) {
      sscanf(line.c_str() + timeIndex, "Time=%d:%d", &hh, &mm);
    }
  }

  int dateIndex = line.lastIndexOf("Date:");
  if (dateIndex >= 0) {
    sscanf(line.c_str() + dateIndex, "Date: %d/%d/%d", &dd, &mo, &yy);
  } else {
    dateIndex = line.lastIndexOf("Date=");
    if (dateIndex >= 0) {
      sscanf(line.c_str() + dateIndex, "Date=%d/%d/%d", &dd, &mo, &yy);
    }
  }

  sprintf(timeStr, "%02d:%02d", hh, mm);
  sprintf(dateStr, "%02d/%02d/%04d", dd, mo, yy);
}

bool parseFloatAfterKey(const String& line, const char* key, float &value) {
  int index = line.indexOf(key);
  if (index < 0) return false;

  return sscanf(line.c_str() + index + strlen(key), "%f", &value) == 1;
}

bool parseTemperature(const String& line, float &temp) {
  if (line.startsWith("T:")) {
    return sscanf(line.c_str(), "T:%f", &temp) == 1;
  }

  if (parseFloatAfterKey(line, "TEMP=", temp)) return true;
  if (parseFloatAfterKey(line, "Temp=", temp)) return true;

  int index = line.indexOf("T:");
  while (index >= 0) {
    bool isTimeWord = (index >= 3 && line.substring(index - 3, index + 2) == "Time:");

    if (!isTimeWord) {
      return sscanf(line.c_str() + index, "T:%f", &temp) == 1;
    }

    index = line.indexOf("T:", index + 2);
  }

  return false;
}

// ================= LINE PARSER =================
void parseLine(String line) {
  line.trim();
  if (line.length() < 5) return;

  Serial.println("📥 Received: " + line);

  char timeStr[12] = "00:00";
  char dateStr[15] = "00/00/0000";
  extractTimeDate(line, timeStr, dateStr);

  float value = 0.0;
  bool sentSomething = false;

  // Parse every sensor found in the line.
  // This protects the system if STM32 messages are accidentally merged.

  if (parseFloatAfterKey(line, "Turb=", value) ||
      parseFloatAfterKey(line, "TURB=", value) ||
      parseFloatAfterKey(line, "Turbidity=", value)) {
    sendSensorToFirebase("/capteurs/turbidite", value, timeStr, dateStr);
    sentSomething = true;
  }

  if (parseFloatAfterKey(line, "pH=", value) || parseFloatAfterKey(line, "PH=", value)) {
    sendSensorToFirebase("/capteurs/ph", value, timeStr, dateStr);
    sentSomething = true;
  }

  if (parseFloatAfterKey(line, "EC=", value) ||
      parseFloatAfterKey(line, "DEC=", value) ||
      parseFloatAfterKey(line, "COND=", value) ||
      parseFloatAfterKey(line, "Conductivity=", value)) {
    sendSensorToFirebase("/capteurs/ec", value, timeStr, dateStr);
    sentSomething = true;
  }

  if (parseTemperature(line, value)) {
    sendSensorToFirebase("/capteurs/temp", value, timeStr, dateStr);
    sentSomething = true;
  }

  if (!sentSomething) {
    Serial.println("⚠️ Unknown frame, not sent: " + line);
  }
}

// ================= COMMAND HANDLER =================
void handleCommand(String cmd) {
  cmd.trim();
  if (cmd.length() == 0 || cmd == "null") return;

  Serial.println("📩 Command sent to STM32: " + cmd);
  mySerial.println(cmd);
}

// ================= SETUP =================
void setup() {
  Serial.begin(9600);
  mySerial.begin(9600);

  Serial.println("\n🚀 ESP8266 Water Quality Monitor Started");

  connectWiFi();
  startGSMServerIfNeeded();

  config.host = FIREBASE_HOST;
  config.signer.tokens.legacy_token = FIREBASE_AUTH;
  config.timeout.serverResponse = 10000;

  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);

  Serial.println("✅ Firebase Ready");
}

// ================= LOOP =================
void loop() {
  // Accepter les configurations GSM envoyees par Python.
  if (WiFi.status() == WL_CONNECTED)
  {
    startGSMServerIfNeeded();
    handleGSMServer();
  }

  // En mode BACKUP, avertir le STM32 uniquement lorsque
  // l'etat effectif du GSM change.
  updateGSMStateToSTM32();

  String line;

  while (readLine(line)) {
    parseLine(line);
    yield();
  }

  static unsigned long lastSettingsCheck = 0;
  if (millis() - lastSettingsCheck > 5000) {
    lastSettingsCheck = millis();
    handleSettingsUpdate();
  }

  static unsigned long lastWifiCheck = 0;
  if (millis() - lastWifiCheck > 15000) {
    lastWifiCheck = millis();
    if (WiFi.status() != WL_CONNECTED) {
      Serial.println("⚠️ WiFi disconnected, reconnecting...");
      connectWiFi();
      startGSMServerIfNeeded();
    }
  }

  static unsigned long lastCmdCheck = 0;
  if (millis() - lastCmdCheck > 3000) {
    lastCmdCheck = millis();

    if (Firebase.ready() && Firebase.getString(firebaseData, "/command")) {
      String cmd = firebaseData.stringData();
      handleCommand(cmd);

      if (cmd.length() > 0 && cmd != "null") {
        Firebase.setString(firebaseData, "/command", "");
      }
    }
  }

  yield();
}