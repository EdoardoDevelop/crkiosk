import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kiosk_mode/kiosk_mode.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:uuid/uuid.dart';

// Import the new HTTP server manager.
import 'http_server_manager.dart';

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

/// Definisce gli stati del ciclo di vita dell'applicazione per una chiara gestione del flusso.
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
  // Salta la configurazione con QR code e memorizza un token fittizio (utile in fase di debug).
  final bool _skipQrConfig = true; // TODO: Cambiare a false per configurare con QR code.

  // Controller per la WebView.
  late final WebViewController _webViewController;
  // Indica se la WebView è stata inizializzata.
  bool _isWebViewInitialized = false;
  // Storage sicuro per dati sensibili come token e password.
  final storage = const FlutterSecureStorage();
  // URL della pagina iniziale della WebView.
  String _urlHome = "https://www.google.com";
  // Password per l'accesso a funzionalità di amministrazione.
  String? _correctPassword;
  // Indica se la WebView sta caricando una pagina.
  bool _isWebViewLoading = true;

  // Istanza del server HTTP manager.
  HttpServerManager? _httpServerManager;
  // Indirizzo IP del server.
  String _serverIp = 'Indirizzo IP non disponibile';
  // Porta del server HTTP.
  final int _serverPort = 3636;
  // Allowed origin per le richieste HTTP (CORS).
  String? _allowedOrigin = '*';
  // Ultimo comando ricevuto dal server.
  String _lastCommand = 'Nessun comando ricevuto';
  // Timestamp dell'ultimo comando ricevuto.
  DateTime? _lastCommandTime;

  // Indica se l'app è impostata come launcher predefinito.
  bool _isLauncherDefault = false;
  // Controlla la visibilità del pannello di amministrazione.
  bool _showPanel = false;
  // ID univoco del dispositivo.
  String? _deviceId;
  // Lista dei log dell'applicazione per il debug.
  final List<String> _logs = [];

  // Stato attuale del ciclo di vita dell'app.
  AppLifecycleState _appState = AppLifecycleState.initial;
  // Token JWT per l'autenticazione.
  String? _jwtToken;

  // Controller per lo scanner di codici a barre/QR.
  final MobileScannerController _mobileScannerController = MobileScannerController();
  // Indica se lo scanner è attivo.
  bool _isScanning = false;
  // Dati estratti dal QR code.
  String? _qrUrl;
  String? _qrHome;
  String? _qrToken;
  String? _qrDeviceId;

  @override
  void initState() {
    super.initState();
    _setupLauncher(); // Configura le impostazioni del launcher all'avvio.
    _initializeApp(); // Avvia il processo di inizializzazione dell'app.
  }

  /// Gestisce il ciclo di vita dell'applicazione, decidendo il flusso iniziale
  /// in base alla presenza di un JWT token.
  Future<void> _initializeApp() async {
    _addLog("Inizializzazione applicazione...");
    setState(() => _appState = AppLifecycleState.initial);

    // Flag di debug per saltare la configurazione QR
    if (_skipQrConfig) {
      await storage.write(key: 'jwtToken', value: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.ey');
    } else {
      // Se non si salta la configurazione, assicurati che il token fittizio venga rimosso se presente
      if (await storage.containsKey(key: 'jwtToken')) {
        if(await storage.read(key: 'jwtToken') == 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.ey') {
          await storage.delete(key: 'jwtToken');
        }
      }
    }

    _jwtToken = await storage.read(key: 'jwtToken');
    if (_jwtToken != null && _jwtToken!.isNotEmpty) {
      _addLog("JWT Token trovato. Caricamento WebView e avvio server.");
      await _loadUrlHome(); // Carica l'URL home prima di inizializzare la webview.
      _initWebView(); // Inizializza la WebView.
      await _loadPassword(); // Carica la password di amministrazione.
      await _loadAllowedOrigin(); // Carica l'allowed origin per CORS.
      await _startHttpServer(); // Avvia il server HTTP.
      await _checkDefaultLauncher(); // Controlla se l'app è il launcher predefinito.
      setState(() {
        _isWebViewInitialized = true;
        _appState = AppLifecycleState.webViewAndServer; // Passa allo stato principale.
      });
    } else {
      _addLog("JWT Token non trovato. Avvio scansione QR code.");
      setState(() {
        _appState = AppLifecycleState.qrScanning; // Passa allo stato di scansione QR.
        _isScanning = true; // Attiva lo scanner.
      });
    }
  }

  /// Aggiunge un messaggio ai log visualizzati e alla console di debug.
  void _addLog(String message) {
    final now = DateTime.now().toLocal();
    final formattedMessage = '[${now.hour}:${now.minute}:${now.second}] $message';

    setState(() {
      _logs.add(formattedMessage);
      // Mantiene solo gli ultimi N log per evitare un consumo eccessivo di memoria.
      if (_logs.length > 50) {
        _logs.removeAt(0);
      }
    });
    if (kDebugMode) {
      print(formattedMessage);
    }
  }

  /// Configura le impostazioni del launcher per la modalità immersiva su Android.
  Future<void> _setupLauncher() async {
    if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: []);
    }
  }

  /// Verifica se l'applicazione è impostata come launcher predefinito su Android.
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

  /// Carica l'URL della pagina iniziale dalla memoria sicura.
  Future<void> _loadUrlHome() async {
    final storedUrl = await storage.read(key: 'urlHome');
    if (storedUrl != null && storedUrl.isNotEmpty) {
      setState(() {
        _urlHome = storedUrl;
      });
    }
    _addLog("URL Home caricato: $_urlHome");
  }

  /// Carica la password dalla memoria sicura, impostando un valore di default se assente.
  Future<void> _loadPassword() async {
    _correctPassword = await storage.read(key: 'password');
    _correctPassword ??= "123456";
  }

  /// Carica l'allowed origin dalla memoria sicura.
  Future<void> _loadAllowedOrigin() async {
    final storedAllowedOrigin = await storage.read(key: 'allowedOrigin');
    if (storedAllowedOrigin != null && storedAllowedOrigin.isNotEmpty) {
      setState(() {
        _allowedOrigin = storedAllowedOrigin;
      });
    }
    _addLog("AllowedOrigin caricato: $_allowedOrigin");
  }

  /// Inizializza il controller della WebView con le impostazioni desiderate e carica l'URL iniziale.
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
    _addLog("WebView inizializzata con URL: $_urlHome");
  }

  /// Avvia un server HTTP locale utilizzando l'HttpServerManager.
  Future<void> _startHttpServer() async {
    // Inizializza l'HTTP server manager se non è già stato fatto.
    _httpServerManager ??= HttpServerManager(
      webViewController: _webViewController,
      storage: storage,
      serverPort: _serverPort,
      initialUrlHome: _urlHome,
      initialAllowedOrigin: _allowedOrigin!,
      addLog: _addLog,
      handleKioskStart: _handleKioskStart,
      handleKioskStop: _handleKioskStop,
      onPasswordChanged: (newPassword) {
        setState(() {
          _correctPassword = newPassword;
        });
      },
      onUrlHomeChanged: (newUrlHome) {
        setState(() {
          _urlHome = newUrlHome;
        });
      },
      onAllowedOriginChanged: (newAllowedOrigin) {
        setState(() {
          _allowedOrigin = newAllowedOrigin;
        });
      },
      onCommandExecuted: (command, timestamp) {
        setState(() {
          _lastCommand = command;
          _lastCommandTime = timestamp;
        });
      },
      onServerIpUpdated: (ipAddress) {
        setState(() {
          _serverIp = ipAddress;
        });
      },
      getDeviceInfo: () {
        return {
          'device_id': _deviceId,
          'kiosk_mode': KioskMode.disabled.toString(), // Questo dovrebbe essere aggiornato dinamicamente dal pacchetto kiosk_mode, placeholder per ora
          'is_launcher_default': _isLauncherDefault,
          'jwt_token_present': _jwtToken != null,
        };
      },
    );

    try {
      await _httpServerManager!.start();
    } catch (e) {
      _addLog('Errore avvio server HTTP: $e');
      setState(() => _appState = AppLifecycleState.error); // Segnala un errore nello stato dell'app.
    }
  }

  /// Gestisce l'esito dell'attivazione della modalità Kiosk.
  void _handleKioskStart(bool didStart) {
    if (!didStart && Platform.isIOS) {
      _addLog(_unsupportedMessage);
    } else {
      _addLog('Modalità Kiosk attivata');
    }
  }

  /// Gestisce l'esito della disattivazione della modalità Kiosk.
  void _handleKioskStop(bool? didStop) {
    if (didStop == false) {
      _addLog('Impossibile disattivare la modalità kiosk');
    } else {
      _addLog('Modalità Kiosk disattivata');
    }
  }

  /// Genera un ID univoco per il dispositivo se non esiste già e lo salva.
  Future<void> _generateDeviceId() async {
    _deviceId = await storage.read(key: 'deviceId');
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = const Uuid().v4(); // Genera un ID univoco.
      await storage.write(key: 'deviceId', value: _deviceId);
      _addLog("Generato Device ID: $_deviceId");
    } else {
      _addLog("Device ID esistente: $_deviceId");
    }
  }

  /// Callback per la rilevazione di codici a barre/QR.
  void _onBarcodeDetected(BarcodeCapture capture) async {
    if (_appState == AppLifecycleState.qrScanning && _isScanning) {
      final barcode = capture.barcodes.firstOrNull;
      if (barcode != null && barcode.rawValue != null) {
        setState(() {
          _isScanning = false; // Ferma la scansione.
          _mobileScannerController.stop(); // Ferma esplicitamente la fotocamera.
          _addLog("QR Code scansionato: ${barcode.rawValue}");
        });

        try {
          final qrData = jsonDecode(barcode.rawValue!);
          _qrUrl = qrData['url'];
          _qrHome = qrData['url_home'];
          _qrToken = qrData['jwt_token'];
          _qrDeviceId = qrData['deviceId']; // ID del dispositivo opzionale dal QR.

          if (_qrUrl != null && Uri.tryParse(_qrUrl!)!.isAbsolute) {
            _addLog("URL dal QR: $_qrUrl");
            setState(() => _appState = AppLifecycleState.registeringDevice); // Passa allo stato di registrazione.
            await _registerDevice(); // Avvia la registrazione del dispositivo.
          } else {
            _addLog("URL non valido nel QR code: $_qrUrl");
            setState(() => _appState = AppLifecycleState.error); // Segnala un errore.
          }
        } catch (e) {
          _addLog("Errore nel parsing del QR code: $e");
          setState(() => _appState = AppLifecycleState.error); // Segnala un errore.
        }
      }
    }
  }

  /// Metodo per riprovare la scansione del QR code.
  void _retryQrScanning() {
    setState(() {
      _qrUrl = null;
      _qrHome = null;
      _qrToken = null;
      _qrDeviceId = null;
      _appState = AppLifecycleState.qrScanning; // Torna allo stato di scansione QR.
      _isScanning = true;
      _mobileScannerController.start(); // Riavvia la fotocamera.
      _addLog("Riprovo scansione QR code.");
    });
  }

  /// Registra il dispositivo con un server remoto utilizzando i dati del QR code.
  Future<void> _registerDevice() async {
    _addLog("Inizio registrazione dispositivo...");
    // Assicura che l'ID del dispositivo sia disponibile prima di procedere.
    await _generateDeviceId();

    final finalDeviceId = _qrDeviceId ?? _deviceId; // Usa l'ID dal QR se presente, altrimenti quello generato.

    try {
      if (kDebugMode) {
        print("Invio richiesta POST a: $_qrUrl con device ID: $finalDeviceId e JWT token: $_qrToken");
      }
      final Map<String, String> bodyData = {
        'ipAddress': _serverIp, // Assicura che _serverIp sia aggiornato (lo farà HttpServerManager)
        'jwt_token': _qrToken!,
      };
      final response = await http.post(
        Uri.parse(_qrUrl!), // Usa l'URL dal QR code.
        headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Authorization': 'Bearer $_qrToken'},
        body: bodyData,
      );

      if (response.statusCode == 200) {
        final responseBody = jsonDecode(response.body);
        if (responseBody['success'] == true) {
          final String? allowOriginHeader = response.headers['access-control-allow-origin'];
          if (allowOriginHeader != null) {
            if (kDebugMode) {
              print("Server ha risposto con Access-Control-Allow-Origin: $allowOriginHeader");
            }

            _jwtToken = _qrToken; // Salva il token JWT.
            if (_jwtToken != null && _jwtToken!.isNotEmpty) {
              await storage.write(key: 'jwtToken', value: _jwtToken);
              await storage.write(key: 'urlHome', value: _qrHome);
              await storage.write(key: 'urlReg', value: _qrUrl);

              if (allowOriginHeader != '*') { // Evita di sovrascrivere se è già '*'
                setState(() {
                  _allowedOrigin = allowOriginHeader;
                });
                await storage.write(key: 'allowedOrigin', value: _allowedOrigin);
              }
              _addLog("Dispositivo registrato con successo. JWT Token salvato.");

              // Procedi allo stato WebView e Server.
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
              _addLog("Registrazione fallita: JWT Token non ricevuto dal server.");
              setState(() => _appState = AppLifecycleState.error);
            }
          } else {
            _addLog("Server non ha specificato l'header Access-Control-Allow-Origin nella risposta.");
          }
        } else {
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
    _httpServerManager?.close(); // Chiude il server HTTP tramite il manager.
    _mobileScannerController.dispose(); // Dispone il controller dello scanner.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(), // Costruisce il corpo della schermata in base allo stato dell'app.
    );
  }

  /// Seleziona il widget da visualizzare in base allo stato attuale dell'applicazione.
  Widget _buildBody() {
    switch (_appState) {
      case AppLifecycleState.initial:
        return _buildInitialView();
      case AppLifecycleState.qrScanning:
        return _buildQrScannerView();
      case AppLifecycleState.registeringDevice:
        return _buildRegisteringDeviceView();
      case AppLifecycleState.webViewAndServer:
        return _buildWebViewAndServerView();
      case AppLifecycleState.error:
        return _buildErrorView();
    }
  }

  /// Widget per lo stato iniziale di caricamento.
  Widget _buildInitialView() {
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
  }

  /// Widget per lo stato di registrazione del dispositivo.
  Widget _buildRegisteringDeviceView() {
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
  }

  /// Widget per la visualizzazione dello scanner QR.
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
                if (!_isScanning && _qrUrl != null)
                  Text('QR Scansionato: $_qrUrl')
                else if (_isScanning)
                  const Text('Inquadra il QR code per la configurazione')
                else
                  const Text('Attendendo scansione QR code...'),
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

  /// Widget per la visualizzazione principale con WebView e pannello di controllo.
  Widget _buildWebViewAndServerView() {
    return StreamBuilder<KioskMode>(
      stream: watchKioskMode(),
      builder: (context, snapshot) {
        final mode = snapshot.data;
        final isKioskEnabled = mode == KioskMode.enabled;
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
            if (_showPanel) _buildAdminPanel(isKioskEnabled), // Pannello di amministrazione.
          ],
        );
      },
    );
  }

  /// Pannello di amministrazione con i pulsanti di controllo e le informazioni.
  Widget _buildAdminPanel(bool isKioskEnabled) {
    return Positioned(
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
                          onPressed: isKioskEnabled
                              ? null
                              : () => startKioskMode().then(_handleKioskStart),
                          child: const Icon(Icons.lock),
                        ),
                        FloatingActionButton(
                          heroTag: 'btn2',
                          onPressed: isKioskEnabled
                              ? () => stopKioskMode().then(_handleKioskStop)
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
                          'Console:\n${_logs.reversed.take(3).join('\n')}',
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
    );
  }

  /// Widget per la visualizzazione di un errore.
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
                _logs.clear(); // Pulisce i log per un nuovo tentativo.
                _initializeApp(); // Riprova l'inizializzazione.
              },
              child: const Text('Riprova'),
            ),
          ],
        ),
      ),
    );
  }
}

// Messaggio di avviso per la modalità Kiosk non supportata.
const _unsupportedMessage = '''
Single App mode è supportato solo per dispositivi gestiti
con Mobile Device Management (MDM) e l'app deve essere
abilitata per questa modalità dal MDM.
''';
