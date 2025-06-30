import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_signal_strength/flutter_signal_strength.dart';
import 'package:kiosk_mode/kiosk_mode.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart'; // Import for mobile_scanner
import 'package:uuid/uuid.dart';
import 'package:battery_plus/battery_plus.dart'; // Import for battery
import 'package:connectivity_plus/connectivity_plus.dart'; // Import for connectivity

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: const HomeLauncherScreen(),
    debugShowCheckedModeBanner: false,
  );
}

// Define the application lifecycle states
enum AppLifecycleState {
  initial,
  qrScanning,
  registeringDevice,
  webViewAndServer,
  error,
}

class HomeLauncherScreen extends StatefulWidget {
  const HomeLauncherScreen({super.key});

  @override
  State<HomeLauncherScreen> createState() => _HomeLauncherScreenState();
}

class _HomeLauncherScreenState extends State<HomeLauncherScreen> {
  late final WebViewController _webViewController;
  bool _isWebViewInitialized = false;
  final storage = const FlutterSecureStorage();
  String _urlHome = "https://www.google.com";
  String? _correctPassword;
  bool _isWebViewLoading = true;
  HttpServer? _server;
  String _serverIp = 'Indirizzo IP non disponibile';
  final int _serverPort = 3636;
  String _lastCommand = 'Nessun comando ricevuto';
  final Battery _battery = Battery(); // Instantiate Battery
  DateTime? _lastCommandTime;
  bool _isLauncherDefault = false;
  bool _showPanel = false;
  String? _deviceId;
  final List<String> _logs = [];

  // New state variable
  AppLifecycleState _appState = AppLifecycleState.initial;
  String? _jwtToken; // To store the JWT token

  // mobile_scanner variables
  final MobileScannerController _mobileScannerController = MobileScannerController();
  bool _isScanning = false; // To control scanner state
  String? _qrUrl; // URL from QR code
  String? _qrDeviceId; // Device ID from QR code
  String? _qrHome;
  String? _qrToken;

  @override
  void initState() {
    super.initState();
    _setupLauncher();
    _initializeApp();
  }

  // New method to manage the app's lifecycle
  Future<void> _initializeApp() async {
    _addLog("Inizializzazione applicazione...");
    setState(() => _appState = AppLifecycleState.initial);

    // 1. Check for existing JWT token
    _jwtToken = await storage.read(key: 'jwtToken');
    if (_jwtToken != null && _jwtToken!.isNotEmpty) {
      _addLog("JWT Token trovato. Caricamento WebView e avvio server.");
      await _loadUrlHome(); // Load home URL before initializing webview
      _initWebView();
      await _startHttpServer();
      await _getLocalIp();
      await _loadPassword();
      await _checkDefaultLauncher();
      setState(() {
        _isWebViewInitialized = true;
        _appState = AppLifecycleState.webViewAndServer;
      });
    } else {
      _addLog("JWT Token non trovato. Avvio scansione QR code.");
      setState(() {
        _appState = AppLifecycleState.qrScanning;
        _isScanning = true; // Start scanning when in QR state
      });
    }
  }

  void _addLog(String message) {
    final now = DateTime.now().toLocal();
    final formattedMessage = '[${now.hour}:${now.minute}:${now.second}] $message';

    setState(() {
      _logs.add(formattedMessage);
      // Manteniamo solo gli ultimi N log per evitare di consumare troppa memoria
      if (_logs.length > 50) {
        _logs.removeAt(0);
      }
    });
    if (kDebugMode) {
      print(formattedMessage);
    }
  }

  Future<void> _setupLauncher() async {
    if (Platform.isAndroid) {
      // Imposta la modalità immersive
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      // Disabilita i pulsanti di sistema
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: [],
      );
    }
  }

  Future<void> _checkDefaultLauncher() async {
    if (Platform.isAndroid) {
      try {
        final isHome = await const MethodChannel('flutter.launcher').invokeMethod('isHomeApp');
        setState(() {
          _isLauncherDefault = isHome == true;
        });
      } catch (e) {
        if (kDebugMode) {
          print("Errore nel verificare lo stato del launcher: $e");
        }
      }
    }
  }

  Future<void> _loadUrlHome() async {
    final storedUrl = await storage.read(key: 'urlHome');
    if (storedUrl != null && storedUrl.isNotEmpty) {
      setState(() {
        _urlHome = storedUrl;
      });
    }
    _addLog("URL Home caricato: $_urlHome");
  }

  Future<void> _loadPassword() async {
    _correctPassword = await storage.read(key: 'password');
    _correctPassword ??= "123456";
  }

  void _initWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => setState(() => _isWebViewLoading = true),
          onPageFinished: (url) => setState(() => _isWebViewLoading = false),
          onWebResourceError: (error) {
            _addLog("WebView Error: ${error.description}");
          },
        ),
      )
      ..loadRequest(Uri.parse(_urlHome));
    _addLog("WebView initializzato con URL: $_urlHome");
  }

  Future<void> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            setState(() => _serverIp = addr.address);
            return;
          }
        }
      }
    } catch (e) {
      _addLog('Errore nel recupero IP: $e');
    }
  }

  Future<void> _startHttpServer() async {
    handler(Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Origin, Content-Type',
          },
        );
      }

      final command = request.url.pathSegments.last;
      final now = DateTime.now();

      setState(() {
        _lastCommand = command;
        _lastCommandTime = now;
      });

      dynamic responseMessage;

      try {
        // Authentication check for sensitive commands (optional, but recommended)
        // If your JWT token should be validated for these commands
        // if (command != 'status' && command != 'ping') {
        //   final authHeader = request.headers['Authorization'];
        //   if (authHeader == null || !authHeader.startsWith('Bearer ') || authHeader.split(' ').last != _jwtToken) {
        //     return Response.forbidden(
        //       jsonEncode({'status': 'error', 'message': 'Unauthorized'}),
        //       headers: {'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json'},
        //     );
        //   }
        // }

        if (command == 'reload') {
          _webViewController.reload();
          responseMessage = 'Pagina ricaricata con successo';
        } else if (command == 'go-home') {
          await _webViewController.loadRequest(Uri.parse(_urlHome));
          responseMessage = 'Tornato alla pagina iniziale';
        } else if (command == 'kiosk-on') {
          final success = await startKioskMode();
          _handleStart(success);
          responseMessage = success ? 'Modalità Kiosk attivata' : 'Fallito attivazione Kiosk';
        } else if (command == 'kiosk-off') {
          final success = await stopKioskMode();
          _handleStop(success);
          responseMessage = success ?? false ? 'Modalità Kiosk disattivata' : 'Fallito disattivazione Kiosk';
        } else if (command == 'status') {
          final mode = await getKioskMode();
          responseMessage = 'Stato attuale: $mode - Ultima pagina: ${await _webViewController.currentUrl()}';
        } else if (command == 'change-pwd') {
          final body = await request.readAsString();
          final jsonBody = jsonDecode(body);
          final newPassword = jsonBody['password'] as String?;

          if (newPassword == null || newPassword.isEmpty) {
            responseMessage = 'Password non fornita o vuota';
          } else {
            await storage.write(key: 'password', value: newPassword);
            setState(() {
              _correctPassword = newPassword;
            });
            responseMessage = 'Password cambiata con successo';
          }
        } else if (command == 'url-home') {
          final body = await request.readAsString();
          final jsonBody = jsonDecode(body);
          final newUrlHome = jsonBody['url'] as String?;

          if (newUrlHome == null || newUrlHome.isEmpty || !Uri.tryParse(newUrlHome)!.isAbsolute) {
            responseMessage = 'URL non fornito, vuoto o non valido.';
          } else {
            await storage.write(key: 'urlHome', value: newUrlHome);
            setState(() {
              _urlHome = newUrlHome;
              _webViewController.loadRequest(Uri.parse(_urlHome)); // Reload webview with new URL
            });
            responseMessage = 'URL Home cambiato con successo a: $_urlHome';
          }
        } else if (command == 'redirect') {
          final body = await request.readAsString();
          final jsonBody = jsonDecode(body);
          final redirectUrl = jsonBody['url'] as String?;
          if (redirectUrl == null || redirectUrl.isEmpty || !Uri.tryParse(redirectUrl)!.isAbsolute) {
            responseMessage = 'URL non fornito, vuoto o non valido.';
          } else {
            await _webViewController.loadRequest(Uri.parse(redirectUrl));
            responseMessage = 'Redirezione effettuata a: $redirectUrl';
          }
        } else if (command == 'device-info') {
          // Get battery info
          final batteryLevel = await _battery.batteryLevel;
          final batteryState = await _battery.batteryState;
          String batteryStatusString = '';
          if (batteryState case BatteryState.full) {
            batteryStatusString = 'Full';
          } else if (batteryState case BatteryState.charging) {
            batteryStatusString = 'Charging';
          } else if (batteryState case BatteryState.discharging) {
            batteryStatusString = 'Discharging';
          } else if (batteryState case BatteryState.unknown) {
            batteryStatusString = 'Unknown';
          }

          // Get WiFi info
          final connectivityResult = await (Connectivity().checkConnectivity());
          String wifiStatus = 'Disconnesso';
          int wifiSignal = 0; // Placeholder for signal strength

          if (connectivityResult.contains(ConnectivityResult.wifi)) {
            wifiStatus = 'Connesso';
            // To get signal strength, you'd typically need another package like network_info_plus
            // For demonstration, we'll just indicate connection status.
            // Example with network_info_plus (uncomment if you add it):
            final flutterSignalStrength = FlutterSignalStrength();
            final wifiSignalStrength = await flutterSignalStrength.getWifiSignalStrength();
            //final wifiBSSID = await networkInfo.getWifiBSSID(); // Can be used to infer connection
            //final wifiIP = await networkInfo.getWifiIP();

            wifiSignal = wifiSignalStrength;

          }
          responseMessage = {
            'ip_address': _serverIp,
            'kiosk_mode': await getKioskMode().then((mode) => mode.toString()),
            'is_launcher_default': _isLauncherDefault,
            'current_url': await _webViewController.currentUrl(),
            'jwt_token_present': _jwtToken != null,
            'battery' : {
              'status': batteryStatusString,
              'level': batteryLevel,
            },
            'wifi' : {
              'status': wifiStatus,
              'signal': wifiSignal,
            },
          };
        } else {
          responseMessage = 'Comando non riconosciuto: $command';
        }

        _addLog('[$now] Comando "$command" eseguito: $responseMessage');

        return Response.ok(
          jsonEncode({
            'status': 'success',
            'command': command,
            'message': responseMessage,
            'timestamp': now.toIso8601String(),
            'current_url': await _webViewController.currentUrl(),
            'kiosk_mode': await getKioskMode().then((mode) => mode.toString()),
            'is_launcher': _isLauncherDefault,
          }),
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Content-Type': 'application/json',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Origin, Content-Type',
          },
        );
      } catch (e) {
        final errorMessage = 'Errore durante l\'esecuzione del comando: $e';
        _addLog('[$now] $errorMessage');

        return Response.internalServerError(
          body: jsonEncode({
            'status': 'error',
            'command': command,
            'message': errorMessage,
            'timestamp': now.toIso8601String(),
          }),
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Content-Type': 'application/json',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Origin, Content-Type',
          },
        );
      }
    }

    try {
      _server = await serve(handler, '0.0.0.0', _serverPort);
      _addLog('Server in ascolto su http://$_serverIp:${_server!.port}');
    } catch (e) {
      _addLog('Errore avvio server HTTP: $e');
      setState(() => _appState = AppLifecycleState.error);
    }
  }

  void _handleStart(bool didStart) {
    if (!didStart && Platform.isIOS) {
      _addLog(_unsupportedMessage);
    } else {
      _addLog('Modalità Kiosk attivata');
    }
  }

  void _handleStop(bool? didStop) {
    if (didStop == false) {
      _addLog('Impossibile disattivare la modalità kiosk');
    } else {
      _addLog('Modalità Kiosk disattivata');
    }
  }

  Future<void> _generateDeviceId() async {
    _deviceId = await storage.read(key: 'deviceId');
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = const Uuid().v4(); // Generate a unique ID
      await storage.write(key: 'deviceId', value: _deviceId);
      _addLog("Generato Device ID: $_deviceId");
    } else {
      _addLog("Device ID esistente: $_deviceId");
    }
  }

  // New method for mobile_scanner barcode detection
  void _onBarcodeDetected(BarcodeCapture capture) async {
    if (_appState == AppLifecycleState.qrScanning && _isScanning) {
      final barcode = capture.barcodes.firstOrNull; // Get the first barcode detected
      if (barcode != null && barcode.rawValue != null) {
        setState(() {
          _isScanning = false; // Stop scanning after first detection
          _mobileScannerController.stop(); // Explicitly stop the camera
          _addLog("QR Code scansionato: ${barcode.rawValue}");
        });

        // Parse QR code data (expecting JSON for URL and optional device ID)
        try {
          final qrData = jsonDecode(barcode.rawValue!);
          _qrUrl = qrData['url'];
          _qrHome = qrData['url_home'];
          _qrToken = qrData['jwt_token'];
          _qrDeviceId = qrData['deviceId']; // Optional device ID from QR

          if (_qrUrl != null && Uri.tryParse(_qrUrl!)!.isAbsolute) {
            _addLog("URL dal QR: $_qrUrl");
            setState(() => _appState = AppLifecycleState.registeringDevice);
            await _registerDevice();
          } else {
            _addLog("URL non valido nel QR code: $_qrUrl");
            setState(() => _appState = AppLifecycleState.error);
          }
        } catch (e) {
          _addLog("Errore nel parsing del QR code: $e");
          setState(() => _appState = AppLifecycleState.error);
        }
      }
    }
  }

  // Method to retry QR scanning
  void _retryQrScanning() {
    setState(() {
      _qrUrl = null;
      _qrHome = null;
      _qrToken = null;
      _qrDeviceId = null;
      _appState = AppLifecycleState.qrScanning;
      _isScanning = true;
      _mobileScannerController.start(); // Restart the camera
      _addLog("Riprovo scansione QR code.");
    });
  }


  // New method for device registration
  Future<void> _registerDevice() async {
    _addLog("Inizio registrazione dispositivo...");
    await _getLocalIp(); // Ensure we have the local IP
    await _generateDeviceId(); // Ensure we have a device ID

    // Use the device ID from QR if provided, otherwise use the generated one
    final finalDeviceId = _qrDeviceId ?? _deviceId;

    try {
      if (kDebugMode) {
        print("Sending POST request to: $_qrUrl with device ID: $finalDeviceId and JWT token: $_qrToken and IP address: $_serverIp");
      }
      final Map<String, String> bodyData = {
        'ipAddress': _serverIp,
        'jwt_token': _qrToken!,
        // Aggiungi altri campi se necessario
      };
      final response = await http.post(
        Uri.parse(_qrUrl!), // Use the URL from the QR code
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: bodyData,
      );

      if (response.statusCode == 200) {
        final responseBody = jsonDecode(response.body);
        //if (kDebugMode) {
        //  print("Registration response: $responseBody");
        //}
        if (responseBody['success'] == true) {
          _jwtToken = _qrToken; // Assuming the server returns a JWT token
          if (_jwtToken != null && _jwtToken!.isNotEmpty) {
            await storage.write(key: 'jwtToken', value: _jwtToken);
            await storage.write(key: 'urlHome', value: _qrHome);
            _addLog("Dispositivo registrato con successo. JWT Token salvato.");

            // Now proceed to WebView and Server state
            await _loadUrlHome();
            _initWebView();
            await _startHttpServer();
            await _loadPassword();
            await _checkDefaultLauncher();
            setState(() {
              _isWebViewInitialized = true;
              _appState = AppLifecycleState.webViewAndServer;
            });
          } else {
            _addLog(
                "Registrazione fallita: JWT Token non ricevuto dal server.");
            setState(() => _appState = AppLifecycleState.error);
          }
        }else{
          if (kDebugMode) {
            print("Registrazione fallita: $responseBody");
          }
          setState(() => _appState = AppLifecycleState.error);
        }
      } else {
        if (kDebugMode) {
          print("Registrazione fallita: ${response.statusCode} - ${response.body}");
        }
        setState(() => _appState = AppLifecycleState.error);
      }
    } catch (e) {
      if (kDebugMode) {
        print("Errore di rete durante la registrazione: $e");
      }
      setState(() => _appState = AppLifecycleState.error);
    }
  }

  @override
  void dispose() {
    _server?.close();
    _mobileScannerController.dispose(); // Dispose mobile_scanner controller
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_appState) {
      case AppLifecycleState.initial:
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Inizializzazione applicazione...'),
            ],
          ),
        );
      case AppLifecycleState.qrScanning:
        return _buildQrScannerView();
      case AppLifecycleState.registeringDevice:
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Registrazione dispositivo...'),
            ],
          ),
        );
      case AppLifecycleState.webViewAndServer:
        return _buildWebViewAndServerView();
      case AppLifecycleState.error:
        return _buildErrorView();
    }
  }

  Widget _buildQrScannerView() {
    return Column(
      children: <Widget>[
        Expanded(
          flex: 4,
          child: Stack(
            children: [
              MobileScanner(
                controller: _mobileScannerController,
                onDetect: _onBarcodeDetected,
              ),
              // You can add an overlay here if you like, similar to qr_code_scanner
              Center(
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.7,
                  height: MediaQuery.of(context).size.width * 0.7,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.red, width: 3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 1,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!_isScanning && _qrUrl != null) // Show scanned content if available
                  Text('QR Scanned: $_qrUrl')
                else if (_isScanning)
                  const Text('Inquadra il QR code per la configurazione')
                else
                  const Text('Attendendo scansione QR code...'), // Default message

                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: _retryQrScanning,
                  child: const Text('Riprova Scansione'),
                ),
              ],
            ),
          ),
        )
      ],
    );
  }

  Widget _buildWebViewAndServerView() {
    return StreamBuilder<KioskMode>(
      stream: watchKioskMode(),
      builder: (context, snapshot) {
        final mode = snapshot.data;
        final isKioskEnabled = mode == KioskMode.enabled;
        /*if (!isKioskEnabled) {
          startKioskMode();
        }*/
        return Stack(
          children: [
            if (_isWebViewInitialized)
              Positioned.fill(
                child: WebViewWidget(
                  controller: _webViewController,
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(),
              ),

            if (_isWebViewInitialized && _isWebViewLoading)
              const Center(
                child: CircularProgressIndicator(),
              ),

            if (_showPanel)
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  setState(() {
                    _showPanel = false;
                  });
                },
              ),

            // Mostra l'icona solo se la modalità kiosk non è attiva
            if (!isKioskEnabled)
              Positioned(
                left: 20,
                bottom: 20,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _showPanel = !_showPanel;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: const BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.settings,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),

            if (_showPanel)
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Card(
                        elevation: 8,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  FloatingActionButton(
                                    heroTag: 'btn1',
                                    onPressed: mode == KioskMode.disabled
                                        ? () => startKioskMode().then(_handleStart)
                                        : null,
                                    child: const Icon(Icons.lock),
                                  ),
                                  FloatingActionButton(
                                    heroTag: 'btn2',
                                    onPressed: mode == KioskMode.enabled
                                        ? () => stopKioskMode().then(_handleStop)
                                        : null,
                                    child: const Icon(Icons.lock_open),
                                  ),
                                  FloatingActionButton(
                                    heroTag: 'btn3',
                                    onPressed: () {
                                      _webViewController.reload();
                                      _addLog('Pagina ricaricata manualmente');
                                    },
                                    child: const Icon(Icons.refresh),
                                  ),
                                  FloatingActionButton(
                                    heroTag: 'btn4',
                                    onPressed: () {
                                      _webViewController.loadRequest(Uri.parse(_urlHome));
                                      _addLog('Tornato alla pagina iniziale manualmente');
                                    },
                                    child: const Icon(Icons.home),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                isKioskEnabled
                                    ? 'Modalità attuale: Kiosk attivo'
                                    : 'Modalità attuale: Kiosk disattivo',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Server: http://$_serverIp:$_serverPort\n'
                                    'Ultimo comando: $_lastCommand\n'
                                    'Ricevuto: ${_lastCommandTime?.toLocal() ?? 'Mai'}\n'
                                    'Console:\n${_logs.reversed.take(3).join('\n')}'
                                ,
                                style: Theme.of(context).textTheme.bodySmall,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Device ID: ${_deviceId ?? 'N/A'}\n'
                                    'Launcher Default: ${_isLauncherDefault ? 'Sì' : 'No'}\n'
                                    'JWT Token Presente: ${_jwtToken != null ? 'Sì' : 'No'}',
                                style: Theme.of(context).textTheme.bodySmall,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 60),
            const SizedBox(height: 20),
            const Text(
              'Si è verificato un errore durante l\'inizializzazione o la registrazione.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              _logs.isNotEmpty ? _logs.last : 'Nessun dettaglio errore disponibile.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: () {
                _logs.clear(); // Clear logs for a fresh start
                _initializeApp(); // Retry initialization
              },
              child: const Text('Riprova'),
            ),
          ],
        ),
      ),
    );
  }
}

const _unsupportedMessage = '''
Single App mode è supportato solo per dispositivi gestiti
con Mobile Device Management (MDM) e l'app deve essere
abilitata per questa modalità dal MDM.
''';