import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart'; 
import 'package:audioplayers/audioplayers.dart'; 

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cirvia',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        primaryColor: const Color(0xFF2979FF), 
        scaffoldBackgroundColor: const Color(0xFFF5F7FA), 
        fontFamily: 'Roboto',
      ),
      home: const BluetoothApp(),
    );
  }
}

class BluetoothApp extends StatefulWidget {
  const BluetoothApp({super.key});

  @override
  State<BluetoothApp> createState() => _BluetoothAppState();
}

class _BluetoothAppState extends State<BluetoothApp> {
  BluetoothConnection? connection;
  List<BluetoothDevice> devices = [];
  BluetoothDevice? selectedDevice;
  bool isConnecting = false;

  final stt.SpeechToText _speechToText = stt.SpeechToText();
  final FlutterTts _flutterTts = FlutterTts(); 
  final AudioPlayer _audioPlayer = AudioPlayer(); 
  
  String _lastWords = '';
  bool _isFireAlertActive = false;
  bool _isGasAlertActive = false;

  bool _mainLightsOn = false;
  bool _hallwayLightsOn = false;
  bool _extraLightsOn = false; 
  bool _doorOpen = false;
  bool _isRaining = false;
  bool _roofClosed = false; 
  bool _garageOpen = false; 
  
  bool _blockGarageSensor = false; 
  bool _carDetected = false; // Safety feature: true while the ultrasonic sensor sees a car in the garage

  int get activeDeviceCount {
    int count = 0;
    if (_mainLightsOn) count++;
    if (_hallwayLightsOn) count++;
    if (_extraLightsOn) count++;
    if (_doorOpen) count++;
    if (_roofClosed) count++;
    if (_garageOpen) count++;
    return count;
  }

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initTts(); 
  }

  void _initTts() async {
    await _flutterTts.awaitSpeakCompletion(true); 
    await _flutterTts.setSpeechRate(0.5); 
    await _flutterTts.setVolume(1.0); 
    await _flutterTts.setPitch(1.0); 
  }

  Future<void> _speak(String text) async {
    await _flutterTts.speak(text);
  }

  Future<void> _playAlarmAndSpeak(String text) async {
    await _flutterTts.stop(); 
    await _audioPlayer.play(AssetSource('sounds/siren.wav')); 
    await Future.delayed(const Duration(seconds: 3)); 
    await _audioPlayer.stop(); 
    await _speak(text); 
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth, Permission.bluetoothScan, 
      Permission.bluetoothConnect, Permission.location, Permission.microphone,
    ].request();

    if (statuses[Permission.bluetoothConnect]!.isGranted || statuses[Permission.bluetooth]!.isGranted) {
      _getPairedDevices();
    } else {
      _showBigNotification("Bluetooth permissions denied", Icons.bluetooth_disabled, Colors.red);
    }

    if (statuses[Permission.microphone]!.isGranted) {
      await _speechToText.initialize();
      setState(() {});
    }
  }

  void _startListening() async {
    if (connection == null || !connection!.isConnected) {
      _showBigNotification("Please connect to a device first", Icons.bluetooth_disabled, Colors.red);
      _speak("Please connect to Bluetooth first."); 
      return;
    }
    _lastWords = '';
    await _flutterTts.stop(); 
    await _speechToText.listen(onResult: _onSpeechResult);
    setState(() {});
  }

  void _stopListening() async {
    await _speechToText.stop();
    setState(() {});
  }

  void _onSpeechResult(SpeechRecognitionResult result) async {
    setState(() {
      _lastWords = result.recognizedWords;
    });
    String command = _lastWords.toLowerCase();
    
    Future<void> executeCommand(Function updateState, String btCommand, String speechText) async {
      await _speechToText.stop(); 
      updateState();
      _sendCommand(btCommand, speakFromUI: false); 
      await Future.delayed(const Duration(milliseconds: 300)); 
      await _speak(speechText); 
    }
    
    // 1. MAIN LIGHT
    if (command.contains('main') && (command.contains('on') || command.contains('open'))) {
      executeCommand(() => setState(() => _mainLightsOn = true), '2', "Okay, main lights turned on.");
    } else if (command.contains('main') && (command.contains('off') || command.contains('close'))) {
      executeCommand(() => setState(() => _mainLightsOn = false), '3', "Okay, main lights turned off.");
    } 
    // 2. HALLWAY LIGHT
    else if (command.contains('hallway') && (command.contains('on') || command.contains('open'))) {
      executeCommand(() => setState(() => _hallwayLightsOn = true), '4', "Okay, hallway lights on.");
    } else if (command.contains('hallway') && (command.contains('off') || command.contains('close'))) {
      executeCommand(() => setState(() => _hallwayLightsOn = false), '5', "Okay, hallway lights off.");
    } 
    // 3. FRONT DOOR
    else if (command.contains('door') && command.contains('open')) {
      executeCommand(() => setState(() => _doorOpen = true), 'O', "Okay, opening the front door.");
    } else if (command.contains('door') && command.contains('close')) {
      executeCommand(() => setState(() => _doorOpen = false), 'C', "Okay, closing the front door.");
    } 
    // 4. PORCH LIGHT
    else if (command.contains('porch') && (command.contains('on') || command.contains('open'))) {
      executeCommand(() => setState(() => _extraLightsOn = true), '1', "Okay, porch light is on.");
    } else if (command.contains('porch') && (command.contains('off') || command.contains('close'))) {
      executeCommand(() => setState(() => _extraLightsOn = false), '0', "Okay, porch light is off.");
    } 
    // 5. SMART ROOF / CLOTHES MODE
    else if (command.contains('clothes') && command.contains('deactivate')) {
      if (_isRaining) {
        executeCommand(() {}, '', "I cannot open the roof while it is raining.");
      } else {
        executeCommand(() => setState(() => _roofClosed = false), '9', "Okay, opening the roof.");
      }
    } else if (command.contains('clothes') && command.contains('activate')) {
      executeCommand(() => setState(() => _roofClosed = true), '8', "Okay, closing the roof to protect the clothes.");
    } 
    // 6. GARAGE DOOR
    else if (command.contains('garage') && command.contains('open')) {
      executeCommand(() => setState(() => _garageOpen = true), 'X', "Okay, opening the garage door.");
    } else if (command.contains('garage') && (command.contains('close') || command.contains('auto'))) {
      // Safety check: never close the garage on a car, even by voice
      if (_carDetected) {
        executeCommand(() {}, '', "Cannot close the garage door because a vehicle is detected.");
      } else {
        executeCommand(() => setState(() => _garageOpen = false), 'Y', "Okay, closing the garage door and returning to auto mode.");
      }
    } 
    // 7. OLED ASSISTANT
    else if (command.contains('wake')) {
      executeCommand(() {}, 'W', "I am awake and ready.");
    } else if (command.contains('angry')) {
      executeCommand(() {}, 'A', "Warning, angry mode activated.");
    }
  }

  Future<void> _getPairedDevices() async {
    try {
      List<BluetoothDevice> pairedDevices = await FlutterBluetoothSerial.instance.getBondedDevices();
      setState(() {
        devices = pairedDevices;
        if (devices.isNotEmpty) {
          try { selectedDevice = devices.firstWhere((d) => d.name == "HC-05"); } 
          catch (e) { selectedDevice = devices.first; }
        }
      });
    } catch (e) {}
  }

  void _connect() async {
    if (selectedDevice == null) return;
    setState(() => isConnecting = true);
    try {
      connection = await BluetoothConnection.toAddress(selectedDevice!.address);
      setState(() => isConnecting = false);
      _showBigNotification('Connected to ${selectedDevice!.name}', Icons.bluetooth_connected, Colors.green);
      _speak("Bluetooth connected.");
      
      connection!.input!.listen(_onDataReceived).onDone(() {
        if (mounted) {
          setState(() {
            connection = null;
            _carDetected = false; 
          });
          _showBigNotification('Disconnected', Icons.bluetooth_disabled, Colors.red);
          _speak("Bluetooth disconnected.");
        }
      });
    } catch (e) {
      setState(() => isConnecting = false);
      _showBigNotification('Connection failed.', Icons.error, Colors.red);
      _speak("Connection failed.");
    }
  }

  void _onDataReceived(Uint8List data) {
    String incomingMsg = ascii.decode(data).trim();
    
    if (incomingMsg.contains('I')) {
      _showBigNotification("MOTION DETECTED\nAT FRONT DOOR!", Icons.directions_walk, Colors.orange);
      _playAlarmAndSpeak("Alert, motion detected at the front door."); 
    } else if (incomingMsg.contains('R')) {
      setState(() { _isRaining = true; _roofClosed = true; });
      _showBigNotification("Rain Detected!\nRoof closed automatically.", Icons.water_drop, Colors.blue);
      _speak("Rain detected. Closing the roof.");
    } else if (incomingMsg.contains('D')) {
      setState(() { _isRaining = false; _roofClosed = false; });
      _showBigNotification("Sunny again!\nRoof opened.", Icons.wb_sunny, Colors.orange);
      _speak("Weather is clear. Opening the roof.");
    } else if (incomingMsg.contains('F') && !_isFireAlertActive) {
      _isFireAlertActive = true;
      _showFireEmergencyDialog();
      _playAlarmAndSpeak("Emergency. Fire detected. Please evacuate immediately."); 
    } else if (incomingMsg.contains('G') && !_isGasAlertActive) {
      _isGasAlertActive = true;
      _showGasEmergencyDialog();
      _playAlarmAndSpeak("Warning. Gas leak detected. Avoid open flames."); 
    } else if (incomingMsg.contains('S')) {
      if (_isFireAlertActive) {
        _isFireAlertActive = false;
        if (Navigator.canPop(context)) Navigator.pop(context); 
        _showBigNotification("Fire alarm cleared.", Icons.check_circle, Colors.green);
      }
      if (_isGasAlertActive) {
        _isGasAlertActive = false;
        if (Navigator.canPop(context)) Navigator.pop(context); 
        _showBigNotification("Gas leak cleared.\nAir is safe.", Icons.check_circle, Colors.green);
      }
    } 
    // Garage status reported by the ultrasonic car sensor
    else if (incomingMsg.contains('U')) {
      if (_blockGarageSensor) return; 
      setState(() {
        _garageOpen = true;
        _carDetected = true; // Car detected
      });
      _showBigNotification("Car Detected!\nGarage Opening.", Icons.directions_car, Colors.blue);
      _speak("Vehicle detected. Opening the garage.");
    } else if (incomingMsg.contains('V')) {
      if (_blockGarageSensor) return; 
      setState(() {
        _garageOpen = false;
        _carDetected = false; // Car has left
      });
      _showBigNotification("Car Cleared.\nGarage Closing.", Icons.check_circle, Colors.green);
      _speak("Vehicle cleared. Closing the garage.");
    } 
    else if (incomingMsg.contains('K')) {
      setState(() => _doorOpen = true); 
      _showBigNotification("Access Granted!\nFront Door Opened.", Icons.meeting_room, Colors.green);
      _speak("Access granted. Front door is open.");
    } else if (incomingMsg.contains('L')) {
      setState(() => _doorOpen = false); 
      _showBigNotification("Door Secured.\nFront Door Closed.", Icons.door_back_door, Colors.orange);
      _speak("Front door is now closed.");
    }
    else if (incomingMsg.contains('Z')) {
      _showBigNotification("ACCESS DENIED!\nUnauthorized Card.", Icons.block, Colors.redAccent);
      _playAlarmAndSpeak("Security alert. Access denied. Unauthorized card detected.");
    }
  }

  void _showFireEmergencyDialog() {
    showDialog(
      context: context, barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.redAccent.shade700,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Column(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.white, size: 60),
              SizedBox(height: 10),
              Text("EMERGENCY ALERT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 24)),
            ],
          ),
          content: const Text("FIRE DETECTED!\nEvacuate immediately. Doors unlocked.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 16)),
          actions: [
            Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.redAccent.shade700),
                child: const Text("Acknowledge", style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () {
                  _isFireAlertActive = false;
                  _audioPlayer.stop(); 
                  Navigator.of(context).pop();
                },
              ),
            )
          ],
        );
      },
    );
  }

  void _showGasEmergencyDialog() {
    showDialog(
      context: context, barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.orangeAccent.shade700,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Column(
            children: [
              Icon(Icons.warning, color: Colors.white, size: 60),
              SizedBox(height: 10),
              Text("GAS LEAK ALERT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 24)),
            ],
          ),
          content: const Text("DANGEROUS GAS DETECTED!\nAvoid using open flames. Please evacuate immediately.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 16)),
          actions: [
            Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.orangeAccent.shade700),
                child: const Text("Acknowledge", style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () {
                  _isGasAlertActive = false;
                  _audioPlayer.stop(); 
                  Navigator.of(context).pop();
                },
              ),
            )
          ],
        );
      },
    );
  }

  void _disconnect() async {
    if (connection != null && connection!.isConnected) {
      await connection!.close();
      setState(() => connection = null);
    }
  }

  void _sendCommand(String text, {bool speakFromUI = true}) async {
    if (connection != null && connection!.isConnected) {
      connection!.output.add(Uint8List.fromList(utf8.encode(text)));
      await connection!.output.allSent;

      String msg = "Command Sent";
      String speechMsg = ""; 
      IconData icon = Icons.check_circle;
      Color color = Colors.black87;

      if (text == '1') { msg = "Porch Light ON"; speechMsg = "Porch light turned on."; icon = Icons.lightbulb; color = Colors.amber; }
      if (text == '0') { msg = "Porch Light OFF"; speechMsg = "Porch light turned off."; icon = Icons.lightbulb_outline; color = Colors.grey; }
      if (text == '2') { msg = "Main Lights ON"; speechMsg = "Main lights turned on."; icon = Icons.lightbulb; color = Colors.amber; }
      if (text == '3') { msg = "Main Lights OFF"; speechMsg = "Main lights turned off."; icon = Icons.lightbulb_outline; color = Colors.grey; }
      if (text == '4') { msg = "Hallway Lights ON"; speechMsg = "Hallway lights turned on."; icon = Icons.linear_scale; color = Colors.amber; }
      if (text == '5') { msg = "Hallway Lights OFF"; speechMsg = "Hallway lights turned off."; icon = Icons.linear_scale; color = Colors.grey; }
      if (text == 'W') { msg = "Assistant Awake"; speechMsg = "Assistant is awake."; icon = Icons.face; color = Colors.purple; }
      if (text == 'A') { msg = "Angry Mode Activated!"; speechMsg = "Angry mode activated."; icon = Icons.sentiment_very_dissatisfied; color = Colors.red; }
      if (text == 'O') { msg = "Opening Front Door..."; speechMsg = "Opening the front door."; icon = Icons.meeting_room; color = Colors.green; }
      if (text == 'C') { msg = "Closing Front Door..."; speechMsg = "Closing the front door."; icon = Icons.door_back_door; color = Colors.orange; }
      if (text == '8') { msg = "Roof manually closed"; speechMsg = "Roof manually closed."; icon = Icons.home; color = Colors.blue; }
      if (text == '9') { msg = "Roof manually opened"; speechMsg = "Roof manually opened."; icon = Icons.wb_sunny; color = Colors.orange; }
      if (text == 'X') { msg = "Garage manually opened"; speechMsg = "Garage manually opened."; icon = Icons.directions_car; color = Colors.green; }
      if (text == 'Y') { msg = "Garage returned to Auto"; speechMsg = "Garage returned to auto mode."; icon = Icons.autorenew; color = Colors.blue; } 
      
      if (text == 'X' || text == 'Y') {
        _blockGarageSensor = true;
        Future.delayed(const Duration(seconds: 4), () {
          _blockGarageSensor = false; 
        });
      }

      _showBigNotification(msg, icon, color);

      if (speakFromUI && speechMsg.isNotEmpty) {
        _speak(speechMsg);
      }
    }
  }

  void _showBigNotification(String message, IconData icon, Color color) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar(); 
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: MediaQuery.of(context).size.height * 0.35, 
          left: 30, right: 30,
        ),
        content: Container(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: color.withOpacity(0.4), width: 2), 
            boxShadow: [
              BoxShadow(color: color.withOpacity(0.25), blurRadius: 30, offset: const Offset(0, 15)) 
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1), 
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 55, color: color),
              ),
              const SizedBox(height: 20),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black87, fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // `statusText` overrides the default "Active" / "Off" label
  Widget _buildSmartCard({required String title, required IconData icon, required bool isActive, required VoidCallback onTap, String? statusText}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: isActive ? const Color(0xFF2979FF).withOpacity(0.25) : Colors.black.withOpacity(0.04), 
              blurRadius: isActive ? 20 : 10, 
              offset: const Offset(0, 5)
            )
          ],
          border: Border.all(color: isActive ? const Color(0xFF2979FF).withOpacity(0.6) : Colors.transparent, width: 2)
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isActive ? const Color(0xFF2979FF).withOpacity(0.15) : const Color(0xFFF0F2F5),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: isActive ? const Color(0xFF2979FF) : Colors.grey.shade500),
            ),
            const SizedBox(height: 16),
            Text(
              title, 
              textAlign: TextAlign.center,
              maxLines: 1, 
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.black87, fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              statusText ?? (isActive ? "Active" : "Off"), 
              style: TextStyle(
                color: statusText == "Car Detected" ? Colors.redAccent : (isActive ? const Color(0xFF2979FF) : Colors.grey.shade600), 
                fontSize: 12, 
                fontWeight: FontWeight.w600
              )
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isConnected = connection != null && connection!.isConnected;

    return Scaffold(
      body: Stack(
        children: [
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 280, 
              padding: const EdgeInsets.only(top: 60, left: 24, right: 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF42A5F5), Color(0xFF1565C0)], 
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(40), bottomRight: Radius.circular(40)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Smart Home", style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                      GestureDetector(
                        onTap: isConnecting ? null : (isConnected ? _disconnect : _connect),
                        child: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth, color: Colors.white, size: 28),
                      )
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded( 
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Welcome back,", style: TextStyle(color: Colors.white70, fontSize: 16)),
                            SizedBox(height: 4),
                            Text("Home Owner", style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900)),
                            SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(Icons.location_on, color: Colors.white70, size: 16),
                                SizedBox(width: 4),
                                Text("Philippines", style: TextStyle(color: Colors.white70, fontSize: 14)), 
                              ],
                            )
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.security, size: 50, color: Colors.white), 
                      )
                    ],
                  ),
                ],
              ),
            ),
          ),

          Positioned(
            top: 230, left: 24, right: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, 10))],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("System Status", style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 10, height: 10,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: isConnected ? Colors.greenAccent.shade400 : Colors.redAccent),
                          ),
                          const SizedBox(width: 8),
                          Text(isConnected ? "Online" : "Offline", style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      )
                    ],
                  ),
                  Container(width: 1, height: 40, color: Colors.grey.shade300), 
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Active Devices", style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text("$activeDeviceCount / 6", style: const TextStyle(color: Color(0xFF2979FF), fontSize: 18, fontWeight: FontWeight.w900)),
                    ],
                  )
                ],
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 310), 
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Control Panel", style: TextStyle(color: Colors.black87, fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 16),
                    
                    GridView.count(
                      crossAxisCount: 2,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 1.05, 
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _buildSmartCard(
                          title: "Main Light", icon: Icons.lightbulb_outline, isActive: _mainLightsOn,
                          onTap: () {
                            if (!isConnected) return _showBigNotification("Connect Bluetooth", Icons.bluetooth, Colors.red);
                            setState(() => _mainLightsOn = !_mainLightsOn);
                            _sendCommand(_mainLightsOn ? '2' : '3');
                          }
                        ),
                        _buildSmartCard(
                          title: "Hallway Light", icon: Icons.linear_scale, isActive: _hallwayLightsOn,
                          onTap: () {
                            if (!isConnected) return _showBigNotification("Connect Bluetooth", Icons.bluetooth, Colors.red);
                            setState(() => _hallwayLightsOn = !_hallwayLightsOn);
                            _sendCommand(_hallwayLightsOn ? '4' : '5');
                          }
                        ),
                        _buildSmartCard(
                          title: "Porch Light", 
                          icon: Icons.tungsten_outlined, isActive: _extraLightsOn,
                          onTap: () {
                            if (!isConnected) return _showBigNotification("Connect Bluetooth", Icons.bluetooth, Colors.red);
                            setState(() => _extraLightsOn = !_extraLightsOn);
                            _sendCommand(_extraLightsOn ? '1' : '0');
                          }
                        ),
                        _buildSmartCard(
                          title: "Front Door", icon: _doorOpen ? Icons.door_front_door_outlined : Icons.door_front_door, isActive: _doorOpen,
                          onTap: () {
                            if (!isConnected) return _showBigNotification("Connect Bluetooth", Icons.bluetooth, Colors.red);
                            setState(() => _doorOpen = !_doorOpen);
                            _sendCommand(_doorOpen ? 'O' : 'C');
                          }
                        ),
                        _buildSmartCard(
                          title: _isRaining ? "Raining Roof" : "Smart Roof", icon: _roofClosed ? Icons.roofing : Icons.wb_sunny_outlined, isActive: _roofClosed,
                          onTap: () {
                            if (!isConnected) return _showBigNotification("Connect Bluetooth", Icons.bluetooth, Colors.red);
                            if (_isRaining) return _showBigNotification("Cannot open while raining!", Icons.water_drop, Colors.blue);
                            setState(() => _roofClosed = !_roofClosed);
                            _sendCommand(_roofClosed ? '8' : '9');
                          }
                        ),
                        // Garage door card with a safety interlock
                        _buildSmartCard(
                          title: "Garage Door", 
                          icon: Icons.garage, 
                          isActive: _garageOpen,
                          statusText: _carDetected ? "Car Detected" : (_garageOpen ? "Open" : "Closed"),
                          onTap: () {
                            if (!isConnected) return _showBigNotification("Connect Bluetooth", Icons.bluetooth, Colors.red);
                            
                            // Block closing while a car is detected
                            if (_garageOpen && _carDetected) {
                              _showBigNotification("SAFETY BLOCK!\nCar is Detected.", Icons.warning_amber_rounded, Colors.redAccent);
                              _speak("Cannot close the garage door. A vehicle is detected.");
                              return;
                            }
                            
                            setState(() => _garageOpen = !_garageOpen);
                            _sendCommand(_garageOpen ? 'X' : 'Y');
                          }
                        ),
                      ],
                    ),
                    const SizedBox(height: 30), 

                    const Text("OLED Assistant", style: TextStyle(color: Colors.black87, fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _buildSmartCard(
                            title: "Wake Up", icon: Icons.face, isActive: false,
                            onTap: () => _sendCommand('W')
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _buildSmartCard(
                            title: "Angry", icon: Icons.sentiment_very_dissatisfied, isActive: false,
                            onTap: () => _sendCommand('A')
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 80), 
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      
      floatingActionButton: FloatingActionButton(
        backgroundColor: _speechToText.isListening ? Colors.redAccent : const Color(0xFF2979FF),
        elevation: 8,
        onPressed: _speechToText.isNotListening ? _startListening : _stopListening,
        child: const Icon(Icons.mic, color: Colors.white, size: 28),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8.0,
        color: Colors.white,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(icon: const Icon(Icons.home, color: Color(0xFF2979FF), size: 30), onPressed: () {}),
              const SizedBox(width: 48), 
              IconButton(icon: const Icon(Icons.person_outline, color: Colors.grey, size: 30), onPressed: () {}),
            ],
          ),
        ),
      ),
    );
  }
}