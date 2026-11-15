// Cirvia: smart home prototype firmware (Arduino Mega 2560)
//
// Talks to the Cirvia Flutter app over an HC-05 Bluetooth module on Serial1.
// The app sends single-character commands; the board replies with single-
// character alerts. See README.md for the full protocol and wiring.

#include <SPI.h>
#include <MFRC522.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <Servo.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>

// --- PIN DEFINITIONS ---
#define RST_PIN 5
#define SS_PIN 8

// --- SHIFT REGISTER 1 PINS (74HC595: main lights) ---
#define LATCH_PIN_1 23
#define CLOCK_PIN_1 22
#define DATA_PIN_1 24

// --- SHIFT REGISTER 2 PINS (74HC595: hallway and side lights) ---
#define LATCH_PIN_2 26
#define CLOCK_PIN_2 25
#define DATA_PIN_2 27

// --- SENSORS & EXTRA LEDs PINS ---
#define IR_PIN 33
#define PIR_PIN 11
#define EXTRA_LED1 37
#define EXTRA_LED2 35
#define SIDE_LED 34     // LED on the opposite side of the house

// --- FLAME SENSOR & FIRE BUZZER PINS ---
#define FLAME_PIN A2
#define FIRE_BUZZER 28

// --- RAIN SENSOR & SMART ROOF PINS ---
#define RAIN_PIN A1
#define SERVO3_PIN 9

// --- GAS SENSOR, BUZZER, & RGB PINS ---
#define GAS_PIN A0
#define GAS_BUZZER 29
#define RED_PIN 46
#define GREEN_PIN 45
#define BLUE_PIN 44

// --- ULTRASONIC & GARAGE PINS ---
#define TRIG_PIN 30
#define ECHO_PIN 31
#define GARAGE_SERVO_PIN 10

// --- MODULE SETUP ---
MFRC522 rfid(SS_PIN, RST_PIN);
LiquidCrystal_I2C lcd(0x27, 16, 2);

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
Adafruit_SH1106G display = Adafruit_SH1106G(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

// --- SERVO SETTINGS ---
Servo servo1;
Servo servo2;
Servo servo3;
Servo servo4;

int s1_Close = 180;
int s2_Close = 0;
int s1_Open = 10;
int s2_Open = 170;

int garage_Close = 150;
int garage_Open = 0;
int distanceThreshold = 7;
int servoSpeed = 20;
bool isGarageOpen = false;

// --- ALARM SETTINGS & THRESHOLDS ---
unsigned long fireTimer = 0;
const int alarmDuration = 3000;
bool isFireAlarmActive = false;

int rainThreshold = 800;
bool isRoofClosed = false;

int gasThreshold = 70;
bool isGasAlarmActive = false;

// --- RFID SETTING ---
String authorizedUID = "XX XX XX XX"; // Replace with your RFID card's UID (see README)

// 📱 --- APP CONTROL VARIABLES ---
bool manualLightOverride = false;
bool manualHallwayOverride = false;
bool mainLightsOn = false;  // Tracks the main lights so shift register 2 can keep the side LEDs in sync
bool irAlertSent = false;
bool fireAlertSent = false;
bool manualRoofClosed = false;
bool manualGarageOpen = false;

void setup() {
  Serial.begin(9600);
  Serial1.begin(9600);
  Wire.begin();

  // 1. SETUP SHIFT REGISTERS
  pinMode(LATCH_PIN_1, OUTPUT);
  pinMode(CLOCK_PIN_1, OUTPUT);
  pinMode(DATA_PIN_1, OUTPUT);
  pinMode(LATCH_PIN_2, OUTPUT);
  pinMode(CLOCK_PIN_2, OUTPUT);
  pinMode(DATA_PIN_2, OUTPUT);

  updateChip1(0b00000000);
  updateChip2(0b00000000);

  // 2. SETUP SENSORS & LEDs
  pinMode(IR_PIN, INPUT);
  pinMode(PIR_PIN, INPUT);
  pinMode(RAIN_PIN, INPUT_PULLUP);

  pinMode(EXTRA_LED1, OUTPUT);
  pinMode(EXTRA_LED2, OUTPUT);
  pinMode(SIDE_LED, OUTPUT);

  pinMode(FLAME_PIN, INPUT_PULLUP);
  pinMode(FIRE_BUZZER, OUTPUT);

  // 3. SETUP GAS & RGB
  pinMode(GAS_PIN, INPUT);
  pinMode(GAS_BUZZER, OUTPUT);
  pinMode(RED_PIN, OUTPUT);
  pinMode(GREEN_PIN, OUTPUT);
  pinMode(BLUE_PIN, OUTPUT);

  digitalWrite(RED_PIN, LOW);
  digitalWrite(GREEN_PIN, LOW);
  digitalWrite(BLUE_PIN, LOW);

  // 4. SETUP ULTRASONIC
  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);

  // 5. OLED INITIALIZATION
  Serial.println("Initializing OLED...");
  if(!display.begin(0x3C, false)) {
    if(!display.begin(0x3D, false)) {
      Serial.println("OLED Failed!");
    }
  }
  display.clearDisplay();
  display.display();
  delay(100);

  // 6. SETUP MODULES
  SPI.begin();
  rfid.PCD_Init();
  lcd.init();
  lcd.backlight();

  updateDisplays("System Starting", "Safety Check...", 1);
  delay(1500);

  // 7. SETUP SERVOS
  servo1.write(s1_Close);
  servo2.write(s2_Close);
  servo1.attach(6);
  servo2.attach(7);
  delay(1000);
  servo1.detach();
  servo2.detach();

  servo3.attach(SERVO3_PIN);
  servo3.write(0);

  servo4.attach(GARAGE_SERVO_PIN);
  servo4.write(garage_Close);

  updateDisplays("Standby...", "Scan RFID Card", 1);
}

void loop() {
  // 📱 TASK 0: BLUETOOTH COMMANDS
  if (Serial1.available() > 0) {
    char command = Serial1.read();
    Serial.print("Phone sent: ");
    Serial.println(command);

    if (command == '1') {
      manualLightOverride = true;
      digitalWrite(EXTRA_LED1, HIGH);
      digitalWrite(EXTRA_LED2, HIGH);
      updateDisplays("Bluetooth Cmd", "Lights ON", 1);
    }
    else if (command == '0') {
      manualLightOverride = false;
      digitalWrite(EXTRA_LED1, LOW);
      digitalWrite(EXTRA_LED2, LOW);
      updateDisplays("Bluetooth Cmd", "Lights OFF", 1);
    }
    // '2' / '3': main lights on / off (also tracked in mainLightsOn)
    else if (command == '2') {
      mainLightsOn = true;
      updateDisplays("Main Lights", "ALL ON", 1);
      updateChip1(0b11111111);
      digitalWrite(SIDE_LED, HIGH);
    }
    else if (command == '3') {
      mainLightsOn = false;
      updateDisplays("Main Lights", "ALL OFF", 1);
      updateChip1(0b00000000);
      digitalWrite(SIDE_LED, LOW);
    }
    // '4' / '5': hallway lights. Shift register 2 itself is updated in Task 1.5
    else if (command == '4') {
      manualHallwayOverride = true;
      updateDisplays("Hallway", "LIGHTS ON", 1);
    }
    else if (command == '5') {
      manualHallwayOverride = false;
      updateDisplays("Hallway", "LIGHTS OFF", 1);
    }
    else if (command == 'W') {
      updateDisplays("Assistant", "I am Awake!", 2);
    }
    else if (command == 'A') {
      updateDisplays("Assistant", "ANGRY MODE!", 3);
    }
    else if (command == 'O') {
      updateDisplays("Door Control", "OPENING...", 1);
      servo1.attach(6);
      servo2.attach(7);
      servo1.write(s1_Open);
      servo2.write(s2_Open);
      delay(1000);
      servo1.detach();
      servo2.detach();
      updateDisplays("Door Control", "DOOR IS OPEN", 1);
    }
    else if (command == 'C') {
      updateDisplays("Door Control", "CLOSING...", 1);
      servo1.attach(6);
      servo2.attach(7);
      servo1.write(s1_Close);
      servo2.write(s2_Close);
      delay(1000);
      servo1.detach();
      servo2.detach();
      updateDisplays("Door Control", "DOOR CLOSED", 1);
    }
    else if (command == '8') {
      manualRoofClosed = true;
      updateDisplays("Smart Roof", "MANUAL CLOSE", 1);
    }
    else if (command == '9') {
      manualRoofClosed = false;
      updateDisplays("Smart Roof", "AUTO MODE", 1);
    }
    else if (command == 'X') {
      manualGarageOpen = true;
      updateDisplays("Garage Door", "MANUAL OPEN", 1);
    }
    else if (command == 'Y') {
      manualGarageOpen = false;
      updateDisplays("Garage Door", "AUTO MODE", 1);
    }
  }

  // 💡 TASK 1: IR SENSOR & EXTRA LEDs
  int irState = digitalRead(IR_PIN);
  if (irState == LOW) {
    if (irAlertSent == false) {
      Serial1.println("I");
      irAlertSent = true;
    }
    digitalWrite(EXTRA_LED1, HIGH);
    digitalWrite(EXTRA_LED2, HIGH);
  } else {
    irAlertSent = false;
    if (manualLightOverride == false) {
      digitalWrite(EXTRA_LED1, LOW);
      digitalWrite(EXTRA_LED2, LOW);
    }
  }

  // 🚶‍♂️ TASK 1.5: PIR SENSOR & SHIFT REGISTER 2 LIGHTS (one combined write, so the app and the sensor never fight)
  int pirState = digitalRead(PIR_PIN);
  byte chip2Data = 0b00000000;

  // 1. Main lights on in the app: turn on the side LEDs (74HC595 pins 15 and 7)
  if (mainLightsOn == true) {
    chip2Data |= 0b10000001;
  }
  // 2. Someone detected by the PIR, or hallway lights on in the app: turn on the middle LEDs
  if (pirState == HIGH || manualHallwayOverride == true) {
    chip2Data |= 0b01111110;
  }

  updateChip2(chip2Data); // Send everything to shift register 2 in a single write

  // 🌧️ TASK 5: SMART ROOF (RAIN SENSOR)
  int rainVal = analogRead(RAIN_PIN);
  bool isRainingNow = (rainVal < rainThreshold); // true when wet, false when dry

  // Raining, or closed manually from the app: close the roof
  if (isRainingNow || manualRoofClosed == true) {
    if (!isRoofClosed) {
      if (isRainingNow) {
        Serial1.println("R"); // Only send the rain alert when it is actually raining
      }
      servo3.attach(SERVO3_PIN);
      servo3.write(80);
      delay(500);
      servo3.detach();
      isRoofClosed = true;
    }
  }
  // Dry and set back to auto in the app: open the roof
  else {
    if (isRoofClosed) {
      Serial1.println("D"); // Send the dry alert to the app
      servo3.attach(SERVO3_PIN);
      servo3.write(0);
      delay(500);
      servo3.detach();
      isRoofClosed = false;
    }
  }

  // 💨 TASK 6: GAS SENSOR & RGB ALARM
  int gasVal = analogRead(GAS_PIN);
  if (gasVal > gasThreshold) {
    if (!isGasAlarmActive) {
      isGasAlarmActive = true;
      Serial1.println("G");
      digitalWrite(RED_PIN, HIGH);
      digitalWrite(GREEN_PIN, LOW);
      digitalWrite(BLUE_PIN, LOW);
    }
    updateDisplays("GAS LEAK!!!", "EVACUATE NOW!", 4);
    tone(GAS_BUZZER, 1000);
  } else {
    if (isGasAlarmActive) {
      isGasAlarmActive = false;
      noTone(GAS_BUZZER);

      if (isGarageOpen) {
        digitalWrite(GREEN_PIN, HIGH);
        digitalWrite(RED_PIN, LOW);
      } else {
        digitalWrite(RED_PIN, LOW);
        digitalWrite(GREEN_PIN, LOW);
        digitalWrite(BLUE_PIN, LOW);
      }

      updateDisplays("Standby...", "Scan RFID Card", 1);
      Serial1.println("S");
    }
  }

  // 🚗 TASK 7: ULTRASONIC & SLOW GARAGE DOOR
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  long duration = pulseIn(ECHO_PIN, HIGH, 30000);
  int distance = duration * 0.034 / 2;

  // Open when a car is closer than distanceThreshold cm, or when opened manually from the app ('X')
  if ((distance > 0 && distance < distanceThreshold) || manualGarageOpen == true) {
    if (!isGarageOpen) {
      if (!isGasAlarmActive) { digitalWrite(GREEN_PIN, HIGH); }

      Serial1.println("U"); // 🚗 SEND 'U' (GARAGE OPEN) TO APP

      servo4.attach(GARAGE_SERVO_PIN);
      for (int pos = garage_Close; pos >= garage_Open; pos -= 1) {
        servo4.write(pos); delay(servoSpeed);
      }
      servo4.detach();

      isGarageOpen = true;
    }
  } else {
    if (isGarageOpen) {
      if (!isGasAlarmActive) { digitalWrite(GREEN_PIN, LOW); }

      Serial1.println("V"); // 🚗 SEND 'V' (GARAGE CLOSED) TO APP

      servo4.attach(GARAGE_SERVO_PIN);
      for (int pos = garage_Open; pos <= garage_Close; pos += 1) {
        servo4.write(pos); delay(servoSpeed);
      }
      servo4.detach();

      isGarageOpen = false;
    }
  }

  // 🔥 TASK 2: FLAME SENSOR & FIRE ALARM
  if (digitalRead(FLAME_PIN) == LOW) {
    fireTimer = millis();
  }

  if (millis() - fireTimer < alarmDuration) {
    if (!isFireAlarmActive) {
      isFireAlarmActive = true;
      Serial1.println("F");
      updateChip1(0b11111111);

      servo1.attach(6);
      servo2.attach(7);
      servo1.write(s1_Open);
      servo2.write(s2_Open);
      delay(500);
      servo1.detach();
      servo2.detach();
    }
    updateDisplays("FIRE ALERT!!!", "EVACUATE NOW!", 4);
    tone(FIRE_BUZZER, 2000);
    delay(150);
    tone(FIRE_BUZZER, 1500);
    delay(150);
  } else {
    noTone(FIRE_BUZZER);
    if (isFireAlarmActive) {
      isFireAlarmActive = false;
      if (!isGasAlarmActive) {
        updateDisplays("Standby...", "Scan RFID Card", 1);
        Serial1.println("S");
      }

      // Fire is over: restore shift register 1 to the state set in the app
      if (mainLightsOn) {
        updateChip1(0b11111111);
      } else {
        updateChip1(0b00000000);
      }

      servo1.attach(6);
      servo2.attach(7);
      servo1.write(s1_Close);
      servo2.write(s2_Close);
      delay(1000);
      servo1.detach();
      servo2.detach();
    }
  }

  // 🚪 TASK 3: RFID DOOR LOCK WITH SIDE LEDs
  if (!isFireAlarmActive && !isGasAlarmActive && rfid.PICC_IsNewCardPresent() && rfid.PICC_ReadCardSerial()) {
    String scannedUID = "";
    for (byte i = 0; i < rfid.uid.size; i++) {
      scannedUID += String(rfid.uid.uidByte[i] < 0x10 ? " 0" : " ");
      scannedUID += String(rfid.uid.uidByte[i], HEX);
    }
    scannedUID.trim();
    scannedUID.toUpperCase();

    if (scannedUID == authorizedUID) {
      updateDisplays("Access Granted!", "Welcome Home", 2);

      // Turn on the lights (main lights + side LEDs)
      updateChip1(0b11111111);
      digitalWrite(SIDE_LED, HIGH);
      updateChip2(0b10000001);
      Serial1.println("K"); // Tell the app ('K') so it updates the UI and announces it
      servo1.attach(6);
      servo2.attach(7);
      servo1.write(s1_Open);
      servo2.write(s2_Open);
      delay(4000);

      updateDisplays("Closing Doors...", "System Secured", 1);

      servo1.write(s1_Close);
      servo2.write(s2_Close);
      Serial1.println("L"); // Tell the app ('L') to switch the door back to closed
      delay(1000);
      servo1.detach();
      servo2.detach();

      // 🛑 Restore the lights to the state set in the app
      if (mainLightsOn) {
        updateChip1(0b11111111);
        digitalWrite(SIDE_LED, HIGH);
      } else {
        updateChip1(0b00000000);
        digitalWrite(SIDE_LED, LOW);
      }
      // No need to update shift register 2 here: Task 1.5 restores it
      // on the next pass through the loop.

    } else {
      Serial1.println("Z");
      updateDisplays("Access Denied!", "Unauthorized ID", 3);
      delay(2000);
    }
    updateDisplays("Standby...", "Scan RFID Card", 1);
    rfid.PICC_HaltA();
    rfid.PCD_StopCrypto1();
  }
}

// --- HELPER FUNCTIONS ---
void updateDisplays(String text1, String text2, int emotion) {
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print(text1);
  lcd.setCursor(0, 1);
  lcd.print(text2);

  display.clearDisplay();

  // Eyes (shared by every expression)
  display.fillCircle(44, 24, 8, SH110X_WHITE);
  display.fillCircle(84, 24, 8, SH110X_WHITE);

  if (emotion == 1) {
    // 😐 NORMAL/NEUTRAL FACE
    display.drawLine(44, 46, 84, 46, SH110X_WHITE);
    display.drawLine(44, 47, 84, 47, SH110X_WHITE);
  }
  else if (emotion == 2) {
    // 😆 HAPPY FACE

    // Cheeks
    display.fillCircle(28, 32, 4, SH110X_WHITE);
    display.fillCircle(100, 32, 4, SH110X_WHITE);

    // Wide open smile (a filled half-circle)
    display.fillCircle(64, 42, 14, SH110X_WHITE);
    // Cover the top half with a black rectangle to leave a U-shaped mouth
    display.fillRect(48, 25, 32, 17, SH110X_BLACK);
  }
  else if (emotion == 3) {
    // 😡 ANGRY FACE (thick eyebrows)
    display.drawLine(30, 10, 50, 20, SH110X_WHITE);
    display.drawLine(30, 11, 50, 21, SH110X_WHITE);
    display.drawLine(30, 12, 50, 22, SH110X_WHITE);

    display.drawLine(98, 10, 78, 20, SH110X_WHITE);
    display.drawLine(98, 11, 78, 21, SH110X_WHITE);
    display.drawLine(98, 12, 78, 22, SH110X_WHITE);

    display.drawCircle(64, 55, 16, SH110X_WHITE);
    display.drawCircle(64, 55, 17, SH110X_WHITE);
    display.fillRect(40, 55, 48, 20, SH110X_BLACK);
  }
  else if (emotion == 4) {
    // 🚨 EMERGENCY / CRITICAL DANGER FACE

    // Erase the default round eyes first
    display.fillCircle(44, 24, 9, SH110X_BLACK);
    display.fillCircle(84, 24, 9, SH110X_BLACK);

    // Left eye: thick 'X'
    display.drawLine(36, 16, 52, 32, SH110X_WHITE);
    display.drawLine(37, 16, 53, 32, SH110X_WHITE);
    display.drawLine(36, 32, 52, 16, SH110X_WHITE);
    display.drawLine(37, 32, 53, 16, SH110X_WHITE);

    // Right eye: thick 'X'
    display.drawLine(76, 16, 92, 32, SH110X_WHITE);
    display.drawLine(77, 16, 93, 32, SH110X_WHITE);
    display.drawLine(76, 32, 92, 16, SH110X_WHITE);
    display.drawLine(77, 32, 93, 16, SH110X_WHITE);

    // Zig-zag mouth (danger)
    display.drawLine(40, 50, 52, 42, SH110X_WHITE);
    display.drawLine(40, 51, 52, 43, SH110X_WHITE);
    display.drawLine(52, 42, 64, 50, SH110X_WHITE);
    display.drawLine(52, 43, 64, 51, SH110X_WHITE);
    display.drawLine(64, 50, 76, 42, SH110X_WHITE);
    display.drawLine(64, 51, 76, 43, SH110X_WHITE);
    display.drawLine(76, 42, 88, 50, SH110X_WHITE);
    display.drawLine(76, 43, 88, 51, SH110X_WHITE);
  }
  display.display();
}

void updateChip1(byte data) {
  digitalWrite(LATCH_PIN_1, LOW);
  shiftOut(DATA_PIN_1, CLOCK_PIN_1, MSBFIRST, data);
  digitalWrite(LATCH_PIN_1, HIGH);
}

void updateChip2(byte data) {
  digitalWrite(LATCH_PIN_2, LOW);
  shiftOut(DATA_PIN_2, CLOCK_PIN_2, MSBFIRST, data);
  digitalWrite(LATCH_PIN_2, HIGH);
}
