;;; lsp-dart-dap.el --- DAP support for lsp-dart -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2020 Eric Dallo
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; DAP support for lsp-dart

;;; Code:

(require 'lsp-mode)
(require 'dap-mode)
(require 'dap-utils)

(require 'lsp-dart-utils)
(require 'lsp-dart-flutter-daemon)
(require 'lsp-dart-devtools)

(defcustom lsp-dart-dap-extension-version "3.25.1"
  "The extension version."
  :group 'lsp-dart
  :type 'string)

(defcustom lsp-dart-dap-extension-url (format "https://github.com/Dart-Code/Dart-Code/releases/download/v%s/dart-code-%s.vsix"
                                              lsp-dart-dap-extension-version
                                              lsp-dart-dap-extension-version)
  "The extension url to download from."
  :group 'lsp-dart
  :type 'string)

(defcustom lsp-dart-dap-debugger-path
  (f-join dap-utils-extension-path (concat  "github/Dart-Code/Dart-Code/" lsp-dart-dap-extension-version))
  "The path to dart vscode extension."
  :group 'lsp-dart
  :type 'string)

(defcustom lsp-dart-dap-dart-debugger-program
  `("node" ,(f-join lsp-dart-dap-debugger-path "extension/out/dist/debug.js") "dart")
  "The path to the dart debugger."
  :group 'lsp-dart
  :type '(repeat string))

(defcustom lsp-dart-dap-dart-test-debugger-program
  `("node" ,(f-join lsp-dart-dap-debugger-path "extension/out/dist/debug.js") "dart_test")
  "The path to the dart test debugger."
  :group 'lsp-dart
  :type '(repeat string))

(defcustom lsp-dart-dap-flutter-debugger-program
  `("node" ,(f-join lsp-dart-dap-debugger-path "extension/out/dist/debug.js") "flutter")
  "The path to the Flutter debugger."
  :group 'lsp-dart
  :type '(repeat string))

(defcustom lsp-dart-dap-flutter-test-debugger-program
  `("node" ,(f-join lsp-dart-dap-debugger-path "extension/out/dist/debug.js") "flutter_test")
  "The path to the dart test debugger."
  :group 'lsp-dart
  :type '(repeat string))

(defcustom lsp-dart-dap-debug-external-libraries nil
  "If non-nil, enable the debug on external libraries."
  :group 'lsp-dart
  :type 'boolean)

(defcustom lsp-dart-dap-debug-sdk-libraries nil
  "If non-nil, enable the debug on Dart SDK libraries."
  :group 'lsp-dart
  :type 'boolean)

(defcustom lsp-dart-dap-evaluate-getters-in-debug-views t
  "If non-nil, evaluate getters in debug views."
  :group 'lsp-dart
  :type 'boolean)

(defcustom lsp-dart-dap-evaluate-tostring-in-debug-views t
  "If non-nil, evaluate toString's in debug views."
  :group 'lsp-dart
  :type 'boolean)

(defcustom lsp-dart-dap-vm-additional-args ""
  "Additional args for dart debugging VM."
  :group 'lsp-dart
  :type 'string)

(defcustom lsp-dart-dap-vm-service-port 0
  "Service port for dart debugging VM."
  :group 'lsp-dart
  :type 'number)

(defcustom lsp-dart-dap-max-log-line-length 2000
  "The max log line length during the debug."
  :group 'lsp-dart
  :type 'number)

(defcustom lsp-dart-dap-flutter-track-widget-creation t
  "Whether to pass –track-widget-creation to Flutter apps.
Required to support 'Inspect Widget'."
  :group 'lsp-dart
  :type 'string)

(defcustom lsp-dart-dap-flutter-structured-errors t
  "Whether to use Flutter's structured error support for improve error display."
  :group 'lsp-dart
  :type 'string)

(defcustom lsp-dart-dap-only-essential-log nil
  "Whether to log only essential log from debugger."
  :group 'lsp-dart
  :type 'boolean)

(defcustom lsp-dart-dap-flutter-hot-reload-on-save nil
  "Send hot reload to flutter during the debug."
  :group 'lsp-dart
  :type 'boolean)

(defcustom lsp-dart-dap-flutter-hot-restart-on-save nil
  "Send hot restart to flutter during the debug."
  :group 'lsp-dart
  :type 'boolean)


;;; Internal

(defun lsp-dart-dap-log (msg &rest args)
  "Log MSG with ARGS adding lsp-dart-dap prefix."
  (apply #'lsp-dart-custom-log "[DAP]" msg args))

(defun lsp-dart-dap--flutter-debugger-args (conf)
  "Add capabilities args on CONF checking dart SDK version."
  (-> conf
      (dap--put-if-absent :flutterSdkPath (lsp-dart-get-flutter-sdk-dir))
      (dap--put-if-absent :flutterTrackWidgetCreation lsp-dart-dap-flutter-track-widget-creation)
      (dap--put-if-absent :useFlutterStructuredErrors lsp-dart-dap-flutter-structured-errors)))

(defun lsp-dart-dap--capabilities-debugger-args (conf)
  "Add capabilities args on CONF checking dart SDK version."
  (-> conf
      (dap--put-if-absent :useWriteServiceInfo (lsp-dart-version-at-least-p "2.7.1"))
      (dap--put-if-absent :debuggerHandlesPathsEverywhereForBreakpoints (lsp-dart-version-at-least-p "2.2.1-edge"))))

(defun lsp-dart-dap--base-debugger-args (conf)
  "Return the base args for debugging merged with CONF."
  (dap--put-if-absent conf :request "launch")
  (dap--put-if-absent conf :dartSdkPath (lsp-dart-get-sdk-dir))
  (dap--put-if-absent conf :maxLogLineLength lsp-dart-dap-max-log-line-length)
  (dap--put-if-absent conf :cwd (lsp-dart-get-project-root))
  (dap--put-if-absent conf :vmAdditionalArgs lsp-dart-dap-vm-additional-args)
  (dap--put-if-absent conf :vmServicePort lsp-dart-dap-vm-service-port)
  (dap--put-if-absent conf :debugExternalLibraries lsp-dart-dap-debug-external-libraries)
  (dap--put-if-absent conf :debugSdkLibraries lsp-dart-dap-debug-sdk-libraries)
  (dap--put-if-absent conf :evaluateGettersInDebugViews lsp-dart-dap-evaluate-getters-in-debug-views)
  (dap--put-if-absent conf :evaluateToStringInDebugViews lsp-dart-dap-evaluate-tostring-in-debug-views)
  (lsp-dart-dap--flutter-debugger-args conf)
  (lsp-dart-dap--capabilities-debugger-args conf))

(defun lsp-dart-dap--enable-mode (&rest _)
  "Enable `lsp-dart-dap-mode'."
  (lsp-dart-dap-mode 1))

(defun lsp-dart-dap--disable-mode (&rest _)
  "Enable `lsp-dart-dap-mode'."
  (lsp-dart-dap-mode -1))

(lsp-dependency
 'dart-debugger
 `(:download :url lsp-dart-dap-extension-url
             :decompress :zip
             :store-path ,(f-join lsp-dart-dap-debugger-path "dart-code")))

;; Dart

(defun lsp-dart-dap--populate-dart-start-file-args (conf)
  "Populate CONF with the required arguments for dart debug."
  (-> conf
      lsp-dart-dap--base-debugger-args
      (dap--put-if-absent :type "dart")
      (dap--put-if-absent :name "Dart")
      (dap--put-if-absent :dap-server-path lsp-dart-dap-dart-debugger-program)
      (dap--put-if-absent :output-filter-function #'lsp-dart-dap--output-filter-function)
      (dap--put-if-absent :program (lsp-dart-get-project-entrypoint))))

(dap-register-debug-provider "dart" 'lsp-dart-dap--populate-dart-start-file-args)
(dap-register-debug-template "Dart :: Debug"
                             (list :type "dart"))

;; Flutter

(declare-function all-the-icons-faicon "ext:all-the-icons")

(defun lsp-dart-dap--device-label (id name is-device platform)
  "Return a friendly label for device with ID, NAME IS-DEVICE and PLATFORM.
Check for icons if supports it."
  (let* ((device-name (if name name id))
         (type-text (if (string= "web" platform)
                        "browser"
                      (if is-device
                          "device"
                        "emulator")))
         (default (concat platform " - " type-text " - " device-name)))
    (if (featurep 'all-the-icons)
        (pcase platform
          ("web" (concat (all-the-icons-faicon "chrome" :face 'all-the-icons-blue :v-adjust 0.0) " " type-text " - " device-name))
          ("android" (concat (all-the-icons-faicon "android" :face 'all-the-icons-green  :v-adjust 0.0) " " type-text " - " device-name))
          ("ios" (concat (all-the-icons-faicon "apple" :face 'all-the-icons-lsilver :v-adjust 0.0) " " type-text " - " device-name))
          (_ default))
      default)))

(defun lsp-dart-dap--flutter-get-or-start-device (callback)
  "Return the device to debug or prompt to start it.
Call CALLBACK when the device is chosen and started successfully."
  (lsp-dart-flutter-daemon-get-devices
   (lambda (devices)
     (if (seq-empty-p devices)
         (lsp-dart-log "No devices found. Try to create a device first via `flutter emulators` command")
       (let ((chosen-device (dap--completing-read "Select a device to debug/run: "
                                                  devices
                                                  (-lambda ((&FlutterDaemonDevice :id :name :is-device? :platform-type platform))
                                                    (lsp-dart-dap--device-label id name is-device? platform))
                                                  nil
                                                  t)))
         (lsp-dart-flutter-daemon-launch chosen-device callback))))))

(defun lsp-dart-dap--output-filter-function (msg)
  "Output filter for dap-mode when parsing MSG."
  (if lsp-dart-dap-only-essential-log
      msg
    ""))

(defun lsp-dart-dap--populate-flutter-start-file-args (conf)
  "Populate CONF with the required arguments for Flutter debug."
  (let ((pre-conf (-> conf
                      lsp-dart-dap--base-debugger-args
                      (dap--put-if-absent :type "flutter")
                      (dap--put-if-absent :flutterMode "debug")
                      (dap--put-if-absent :dap-server-path lsp-dart-dap-flutter-debugger-program)
                      (dap--put-if-absent :output-filter-function #'lsp-dart-dap--output-filter-function)
                      (dap--put-if-absent :program (lsp-dart-get-project-entrypoint)))))
    (lambda (start-debugging-callback)
      (lsp-dart-dap--flutter-get-or-start-device
       (-lambda ((&hash "id" device-id "name" device-name))
         (funcall start-debugging-callback
                  (-> pre-conf
                      (dap--put-if-absent :deviceId device-id)
                      (dap--put-if-absent :deviceName device-name)
                      (dap--put-if-absent :flutterPlatform "default")
                      (dap--put-if-absent :name (concat "Flutter (" device-name ")")))))))))

(dap-register-debug-provider "flutter" 'lsp-dart-dap--populate-flutter-start-file-args)
(dap-register-debug-template "Flutter :: Debug"
                             (list :type "flutter"))

(defvar lsp-dart-dap--flutter-progress-reporter nil)
(defvar lsp-dart-dap--flutter-progress-reporter-timer nil)

(defconst lsp-dart-dap--debug-prefix
  (concat (propertize "[LSP Dart] "
                      'face 'font-lock-keyword-face)
          (propertize "[DAP] "
                      'face 'font-lock-function-name-face)))

(defun lsp-dart-dap--cancel-flutter-progress (_debug-session)
  "Cancel the Flutter progress timer for DEBUG-SESSION."
  (setq lsp-dart-dap--flutter-progress-reporter nil)
  (when lsp-dart-dap--flutter-progress-reporter-timer
    (cancel-timer lsp-dart-dap--flutter-progress-reporter-timer))
  (setq lsp-dart-dap--flutter-progress-reporter-timer nil))

(add-hook 'dap-terminated-hook #'lsp-dart-dap--cancel-flutter-progress)

(defun lsp-dart-dap--flutter-tick-progress-update ()
  "Update the flutter progress reporter."
  (when lsp-dart-dap--flutter-progress-reporter
    (progress-reporter-update lsp-dart-dap--flutter-progress-reporter)))

(defun lsp-dart-dap--parse-log-message (raw)
  "Parse log RAW from debugger events."
  (let ((msg (--> raw
                  (replace-regexp-in-string (regexp-quote "<== ") "" it nil)
                  (replace-regexp-in-string (regexp-quote "==> ") "" it nil)
                  (replace-regexp-in-string (regexp-quote "\^M") "" it nil))))
    (condition-case nil
        (if (booleanp (lsp--read-json msg))
            nil)
      ('error msg))))

(cl-defmethod dap-handle-event ((_event (eql dart.log)) _session params)
  "Handle debugger uris EVENT for SESSION with PARAMS."
  (unless lsp-dart-dap-only-essential-log
    (when-let (dap-session (dap--cur-session))
      (-let* (((&hash "message") params))
        (when-let (msg (lsp-dart-dap--parse-log-message message))
          (dap--print-to-output-buffer dap-session msg))))))

(cl-defmethod dap-handle-event ((_event (eql dart.progressStart)) _session params)
  "Handle debugger uris EVENT for SESSION with PARAMS."
  (setq lsp-dart-dap--flutter-progress-reporter
        (make-progress-reporter (concat lsp-dart-dap--debug-prefix (gethash "message" params))))
  (setq lsp-dart-dap--flutter-progress-reporter-timer
        (run-with-timer 0.2 0.2 #'lsp-dart-dap--flutter-tick-progress-update)))

(cl-defmethod dap-handle-event ((_event (eql dart.progressEnd)) _session _params)
  "Handle debugger uris EVENT for SESSION with PARAMS."
  (lsp-dart-dap--cancel-flutter-progress (dap--cur-session)))

(cl-defmethod dap-handle-event ((_event (eql dart.progressUpdate)) _session params)
  "Handle debugger uris EVENT for SESSION with PARAMS."
  (-let (((&hash "message") params))
    (when (and message lsp-dart-dap--flutter-progress-reporter)
      (progress-reporter-force-update lsp-dart-dap--flutter-progress-reporter nil (concat lsp-dart-dap--debug-prefix message)))))

(cl-defmethod dap-handle-event ((_event (eql dart.flutter.firstFrame)) _session _params)
  "Handle debugger uris EVENT for SESSION with PARAMS."
  (lsp-dart-dap-log "App ready!"))

(cl-defmethod dap-handle-event ((_event (eql dart.exposeUrl)) session params)
  "Respond SESSION with the url from given PARAMS."
  (-let (((&hash "url") params))
    (dap-request session "exposeUrlResponse"
                 :originalUrl url
                 :exposedUrl url)))

(cl-defmethod dap-handle-event ((_event (eql dart.webLaunchUrl)) _session params)
  "Open url in browser from SESSION and PARAMS."
  (-let (((&hash "launched" "url") params))
    (unless launched
      (browse-url url))))

(cl-defmethod dap-handle-event ((_event (eql dart.hotRestartRequest)) _session _params)
  "Ignore this event.")
(cl-defmethod dap-handle-event ((_event (eql dart.hotReloadRequest)) _session _params)
  "Ignore this event.")
(cl-defmethod dap-handle-event ((_event (eql dart.debugMetrics)) _session _params)
  "Ignore this event.")
(cl-defmethod dap-handle-event ((_event (eql dart.navigate)) _session _params)
  "Ignore this event.")
(cl-defmethod dap-handle-event ((_event (eql dart.serviceExtensionAdded)) _session _params)
  "Ignore this event.")
(cl-defmethod dap-handle-event ((_event (eql dart.serviceRegistered)) _session _params)
  "Ignore this event.")
(cl-defmethod dap-handle-event ((_event (eql dart.flutter.serviceExtensionStateChanged)) _session _params)
  "Ignore this event.")
(cl-defmethod dap-handle-event ((_event (eql dart.flutter.updatePlatformOverride)) _session _params)
  "Ignore this event.")
(cl-defmethod dap-handle-event ((_event (eql dart.flutter.updateIsWidgetCreationTracked)) _session _params)
  "Ignore this event.")

(cl-defmethod dap-handle-event ((_event (eql dart.testRunNotification)) _session _params)
  "Ignore this event.")

(defun lsp-dart-dap--flutter-hot-reload ()
  "Hot reload current Flutter debug session."
  (dap-request (dap--cur-session) "hotReload"))

(defun lsp-dart-dap--flutter-hot-restart ()
  "Hot restart current Flutter debug session."
  (dap-request (dap--cur-session) "hotRestart"))

(defun lsp-dart-dap--on-save ()
  "Run when `after-save-hook' is triggered."
  (if lsp-dart-dap-flutter-hot-restart-on-save
      (lsp-dart-dap--flutter-hot-restart)
    (when lsp-dart-dap-flutter-hot-reload-on-save
      (lsp-dart-dap--flutter-hot-reload))))


;; Public

(defun lsp-dart-dap-run-dart (&optional path args)
  "Start Dart application without debugging.
Run program PATH if not nil passing ARGS if not nil."
  (-> (list :type "dart"
            :name "Dart Run"
            :program path
            :args args
            :noDebug t)
      lsp-dart-dap--populate-dart-start-file-args
      dap-start-debugging))

(defun lsp-dart-dap-run-flutter (&optional path args)
  "Start Flutter app without debugging.
Run program PATH if not nil passing ARGS if not nil."
  (-> (list :type "flutter"
            :name "Flutter Run"
            :program path
            :args args
            :noDebug t)
      lsp-dart-dap--populate-flutter-start-file-args
      (funcall #'dap-start-debugging)))

(defun lsp-dart-dap-debug-dart (path)
  "Debug dart application from PATH."
  (-> (list :program path)
      lsp-dart-dap--populate-dart-start-file-args
      dap-start-debugging))

(defun lsp-dart-dap-debug-flutter (path)
  "Debug Flutter application from PATH."
  (-> (list :program path)
      lsp-dart-dap--populate-flutter-start-file-args
      (funcall #'dap-start-debugging)))

(defun lsp-dart-dap-debug-dart-test (path &optional args)
  "Start dart test debugging from PATH with ARGS."
  (-> (list :type "dart"
            :name "Dart Tests"
            :dap-server-path lsp-dart-dap-dart-test-debugger-program
            :program path
            :noDebug nil
            :shouldConnectDebugger t
            :args args)
      lsp-dart-dap--base-debugger-args
      dap-start-debugging))

(defun lsp-dart-dap-debug-flutter-test (path &optional args)
  "Start dart test debugging from PATH with ARGS."
  (-> (list :name "Flutter Tests"
            :type "flutter"
            :dap-server-path lsp-dart-dap-flutter-test-debugger-program
            :program path
            :noDebug nil
            :shouldConnectDebugger t
            :flutterMode "debug"
            :args args)
      lsp-dart-dap--base-debugger-args
      dap-start-debugging))


;; Public Interface

(defun lsp-dart-dap-setup ()
  "Install the Dart/Flutter debugger extension."
  (interactive)
  (lsp-package-ensure 'dart-debugger
                      (lambda (&rest _) (lsp-dart-log "Dart debugger installed successfully!"))
                      (lambda (e)
                        (lsp-dart-log "Error installing Dart debugger. %s" e))))

(defun lsp-dart-dap-flutter-hot-restart ()
  "Hot restart current Flutter debug session."
  (interactive)
  (lsp-dart-dap--flutter-hot-restart))

(defun lsp-dart-dap-flutter-hot-reload ()
  "Hot reload current Flutter debug session."
  (interactive)
  (lsp-dart-dap--flutter-hot-reload))

(define-minor-mode lsp-dart-dap-mode
  "Mode for when debugging Dart/Flutter code."
  :global nil
  :init-value nil
  :lighter nil
  (cond
   (lsp-dart-dap-mode
    (add-hook 'after-save-hook #'lsp-dart-dap--on-save))
   (t
    (remove-hook 'after-save-hook #'lsp-dart-dap--on-save))))

(add-hook 'dap-session-created-hook #'lsp-dart-dap--enable-mode)
(add-hook 'dap-terminated-hook #'lsp-dart-dap--disable-mode)

(provide 'lsp-dart-dap)
;;; lsp-dart-dap.el ends here
