import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:kiosk_mode/kiosk_mode.dart';

// Define typedefs for callbacks to communicate with the UI
typedef LogCallback = void Function(String message);
typedef KioskStatusCallback = void Function(bool didStart);
typedef PasswordChangedCallback = void Function(String newPassword);
typedef UrlHomeChangedCallback = void Function(String newUrlHome);
typedef AllowedOriginChangedCallback = void Function(String newAllowedOrigin);
typedef CommandExecutedCallback = void Function(String command, DateTime timestamp);
typedef ServerIpCallback = void Function(String ipAddress);
// Callback per ottenere informazioni dinamiche sul dispositivo dall'UI (es. ID dispositivo, stato launcher, presenza token JWT).
typedef DeviceInfoCallback = Map<String, dynamic> Function();

/// Gestisce il server HTTP locale e le sue interazioni,
/// astraendo la logica del server dal widget UI principale.
class HttpServerManager {
  HttpServer? _server; // Istanza del server HTTP.
  final int _serverPort; // Porta su cui il server è in ascolto.
  final WebViewController _webViewController; // Controller per le operazioni della WebView.
  final FlutterSecureStorage _storage; // Storage sicuro per dati sensibili.
  final LogCallback _addLog; // Callback per aggiungere messaggi ai log dell'applicazione.
  final KioskStatusCallback _handleKioskStart; // Callback per lo stato di attivazione della modalità kiosk.
  final KioskStatusCallback _handleKioskStop; // Callback per lo stato di disattivazione della modalità kiosk.
  final PasswordChangedCallback _onPasswordChanged; // Callback quando la password viene cambiata.
  final UrlHomeChangedCallback _onUrlHomeChanged; // Callback quando l'URL home viene cambiato.
  final AllowedOriginChangedCallback _onAllowedOriginChanged; // Callback quando l'origin consentito viene cambiato.
  final CommandExecutedCallback _onCommandExecuted; // Callback quando un comando viene eseguito.
  final ServerIpCallback _onServerIpUpdated; // Callback per aggiornare l'IP del server nell'UI.
  final DeviceInfoCallback _getDeviceInfo; // Callback per recuperare informazioni dinamiche sul dispositivo dall'UI.

  // Variabili di stato interne gestite dal server manager.
  String _currentUrlHome;
  String _currentAllowedOrigin;
  String? _currentCorrectPassword; // La password di amministrazione corrente.
  String _currentServerIp = 'Indirizzo IP non disponibile'; // L'indirizzo IP locale del server.

  /// Costruttore per HttpServerManager.
  ///
  /// Richiede vari controller, storage, porta, valori iniziali e callback
  /// per interagire con l'UI e altre parti dell'applicazione.
  HttpServerManager({
    required WebViewController webViewController,
    required FlutterSecureStorage storage,
    required int serverPort,
    required String initialUrlHome,
    required String initialAllowedOrigin,
    required LogCallback addLog,
    required KioskStatusCallback handleKioskStart,
    required KioskStatusCallback handleKioskStop,
    required PasswordChangedCallback onPasswordChanged,
    required UrlHomeChangedCallback onUrlHomeChanged,
    required AllowedOriginChangedCallback onAllowedOriginChanged,
    required CommandExecutedCallback onCommandExecuted,
    required ServerIpCallback onServerIpUpdated,
    required DeviceInfoCallback getDeviceInfo,
  })  : _webViewController = webViewController,
        _storage = storage,
        _serverPort = serverPort,
        _currentUrlHome = initialUrlHome,
        _currentAllowedOrigin = initialAllowedOrigin,
        _addLog = addLog,
        _handleKioskStart = handleKioskStart,
        _handleKioskStop = handleKioskStop,
        _onPasswordChanged = onPasswordChanged,
        _onUrlHomeChanged = onUrlHomeChanged,
        _onAllowedOriginChanged = onAllowedOriginChanged,
        _onCommandExecuted = onCommandExecuted,
        _onServerIpUpdated = onServerIpUpdated,
        _getDeviceInfo = getDeviceInfo;

  /// Avvia il server HTTP locale.
  ///
  /// Questo metodo recupera l'IP locale, carica la password e l'origin consentito,
  /// quindi configura l'handler delle richieste HTTP e inizia ad ascoltare le richieste.
  Future<void> start() async {
    await _getLocalIp(); // Recupera l'IP prima di avviare il server.
    await _loadPassword(); // Carica la password per la gestione del comando 'change-pwd'.
    await _loadAllowedOrigin(); // Carica l'origin consentito per gli header CORS.

    // Handler per le richieste HTTP in arrivo.
    handler(Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: {
            'Access-Control-Allow-Origin': _currentAllowedOrigin,
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Origin, Content-Type',
          },
        );
      }
      final command = request.url.pathSegments.last; // Estrae il comando dal percorso URL.
      final now = DateTime.now(); // Registra l'ora corrente.

      // Notifica l'UI sull'ultimo comando eseguito e il suo timestamp.
      _onCommandExecuted(command, now);

      String responseMessage;

      try {
        // Gestisce i diversi comandi ricevuti dal server.
        switch (command) {
          case 'reload':
            _webViewController.reload();
            responseMessage = 'Pagina ricaricata con successo';
            break;
          case 'go-home':
            await _webViewController.loadRequest(Uri.parse(_currentUrlHome));
            responseMessage = 'Tornato alla pagina iniziale';
            break;
          case 'kiosk-on':
            final success = await startKioskMode();
            _handleKioskStart(success); // Notifica l'UI sullo stato della modalità kiosk.
            responseMessage = success ? 'Modalità Kiosk attivata' : 'Fallito attivazione Kiosk';
            break;
          case 'kiosk-off':
            final success = await stopKioskMode();
            _handleKioskStop(success!); // Notifica l'UI sullo stato della modalità kiosk.
            responseMessage = success ? 'Modalità Kiosk disattivata' : 'Fallito disattivazione Kiosk';
            break;
          case 'status':
            final mode = await getKioskMode(); // Ottiene lo stato attuale della modalità kiosk.
            final currentUrl = await _webViewController.currentUrl(); // Ottiene l'URL corrente della WebView.
            responseMessage = 'Stato attuale: $mode - Ultima pagina: $currentUrl';
            break;
          case 'change-pwd':
            final body = await request.readAsString();
            final jsonBody = jsonDecode(body);
            final newPassword = jsonBody['password'] as String?;
            if (newPassword == null || newPassword.isEmpty) {
              responseMessage = 'Password non fornita o vuota';
            } else {
              await _storage.write(key: 'password', value: newPassword);
              _currentCorrectPassword = newPassword; // Aggiorna lo stato interno.
              _onPasswordChanged(newPassword); // Notifica l'UI sul cambio password.
              responseMessage = 'Password cambiata con successo';
            }
            break;
          case 'url-home':
            final body = await request.readAsString();
            final jsonBody = jsonDecode(body);
            final newUrlHome = jsonBody['url'] as String?;
            // Valida il nuovo URL.
            if (newUrlHome == null || newUrlHome.isEmpty || !Uri.tryParse(newUrlHome)!.isAbsolute) {
              responseMessage = 'URL non fornito, vuoto o non valido.';
            } else {
              await _storage.write(key: 'urlHome', value: newUrlHome);
              _currentUrlHome = newUrlHome; // Aggiorna lo stato interno.
              _onUrlHomeChanged(newUrlHome); // Notifica l'UI sul cambio dell'URL home.
              await _webViewController.loadRequest(Uri.parse(_currentUrlHome)); // Ricarica la WebView con il nuovo URL.
              responseMessage = 'URL Home cambiato con successo a: $_currentUrlHome';
            }
            break;
          case 'redirect':
            final body = await request.readAsString();
            final jsonBody = jsonDecode(body);
            final redirectUrl = jsonBody['url'] as String?;
            // Valida l'URL di reindirizzamento.
            if (redirectUrl == null || redirectUrl.isEmpty || !Uri.tryParse(redirectUrl)!.isAbsolute) {
              responseMessage = 'URL non fornito, vuoto o non valido.';
            } else {
              await _webViewController.loadRequest(Uri.parse(redirectUrl));
              responseMessage = 'Redirezione effettuata a: $redirectUrl';
            }
            break;
          case 'device-info':
          // Recupera le informazioni dinamiche del dispositivo dallo strato UI tramite callback.
            final deviceInfo = _getDeviceInfo();
            responseMessage = jsonEncode({
              'device_id': deviceInfo['device_id'],
              'ip_address': _currentServerIp, // Usa l'IP interno per la risposta.
              'kiosk_mode': deviceInfo['kiosk_mode'],
              'is_launcher_default': deviceInfo['is_launcher_default'],
              'current_url': await _webViewController.currentUrl(),
              'jwt_token_present': deviceInfo['jwt_token_present'],
            });
            break;
          default:
            responseMessage = 'Comando non riconosciuto: $command';
        }

        // Logga il comando eseguito e la sua risposta.
        _addLog('[$now] Comando "$command" eseguito: $responseMessage');

        // Restituisce una risposta HTTP di successo.
        return Response.ok(
          jsonEncode({
            'status': 'success',
            'command': command,
            'message': responseMessage,
            'timestamp': now.toIso8601String()
          }),
          headers: {
            'Access-Control-Allow-Origin': _currentAllowedOrigin,
            'Content-Type': 'application/json',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Origin, Content-Type',
          },
        );
      } catch (e) {
        final errorMessage = 'Errore durante l\'esecuzione del comando: $e';
        _addLog('[$now] $errorMessage');

        // Restituisce una risposta di errore interno del server se si verifica un'eccezione.
        return Response.internalServerError(
          body: jsonEncode({
            'status': 'error',
            'command': command,
            'message': errorMessage,
            'timestamp': now.toIso8601String(),
          }),
          headers: {
            'Access-Control-Allow-Origin': _currentAllowedOrigin,
            'Content-Type': 'application/json',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Origin, Content-Type',
          },
        );
      }
    }

    try {
      // Inizia a servire le richieste HTTP.
      _server = await serve(handler, '0.0.0.0', _serverPort);
      _addLog('Server in ascolto su http://$_currentServerIp:${_server!.port}');
    } catch (e) {
      _addLog('Errore avvio server HTTP: $e');
      // Nota: Il cambio di stato dell'app (es. a stato di errore) dovrebbe essere gestito dal chiamante.
    }
  }

  /// Recupera l'indirizzo IPv4 locale del dispositivo.
  ///
  /// Itera attraverso le interfacce di rete per trovare un indirizzo IPv4 non di loopback
  /// e aggiorna lo stato interno e notifica l'UI.
  Future<void> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            _currentServerIp = addr.address;
            _onServerIpUpdated(addr.address); // Notifica l'UI che l'indirizzo IP è stato aggiornato.
            return;
          }
        }
      }
    } catch (e) {
      _addLog('Errore nel recupero IP: $e');
    }
  }

  /// Carica la password di amministrazione dallo storage sicuro.
  /// Se non viene trovata alcuna password, viene impostato il valore predefinito "123456".
  Future<void> _loadPassword() async {
    _currentCorrectPassword = await _storage.read(key: 'password');
    _currentCorrectPassword ??= "123456"; // Password predefinita se non è memorizzata.
  }

  /// Carica l'origin consentito per CORS dallo storage sicuro.
  /// Questo origin viene utilizzato nell'header 'Access-Control-Allow-Origin' delle risposte HTTP.
  Future<void> _loadAllowedOrigin() async {
    final storedAllowedOrigin = await _storage.read(key: 'allowedOrigin');
    if (storedAllowedOrigin != null && storedAllowedOrigin.isNotEmpty) {
      _currentAllowedOrigin = storedAllowedOrigin;
      _onAllowedOriginChanged(storedAllowedOrigin); // Notifica l'UI sul cambio dell'origin consentito.
    }
    _addLog("AllowedOrigin caricato: $_currentAllowedOrigin");
  }

  /// Chiude il server HTTP in modo elegante.
  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _addLog('Server HTTP chiuso.');
  }

  // Getters for external access to server properties.
  String get serverIp => _currentServerIp;
  int get serverPort => _serverPort;
}
