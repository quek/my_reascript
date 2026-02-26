;;; jsfx-mode.el --- Major mode for editing REAPER JSFX files -*- lexical-binding: t; -*-

;; Author: Yoshino
;; Version: 2.0.0
;; Keywords: languages, audio, dsp
;; URL: https://www.reaper.fm/sdk/js/js.php

;;; Commentary:

;; Major mode for REAPER's JSFX (EEL2) audio effect scripting language.
;;
;; Features:
;;   - Syntax highlighting for sections, directives, keywords, builtins,
;;     special variables, constants, strings, and comments
;;   - Automatic indentation based on () block nesting
;;   - Imenu support for section and function navigation
;;   - Context-aware completion:
;;       * All built-in functions and special variables
;;       * Functions from imported .jsfx-inc files (auto-parsed)
;;       * Slider variable names from file headers
;;   - REAPER integration (optional, via jsfx-server.lua):
;;       * Auto-reload JSFX on save
;;       * Query FX parameters from running REAPER
;;       * Interactive commands: M-x jsfx-reaper-*
;;   - File associations for .jsfx and .jsfx-inc
;;
;; Installation:
;;   (add-to-list 'load-path "/path/to/directory/")
;;   (require 'jsfx-mode)
;;
;; REAPER Integration:
;;   1. Load jsfx-server.lua as a ReaScript action in REAPER
;;   2. Run the action to start the IPC server
;;   3. M-x jsfx-reaper-ping to verify connection
;;   4. Set jsfx-auto-reload to t (default) for reload on save

;;; Code:

;; ============================================================
;;; Customization
;; ============================================================

(defgroup jsfx nil
  "Major mode for REAPER JSFX (EEL2) files."
  :group 'languages
  :prefix "jsfx-")

(defcustom jsfx-indent-offset 2
  "Number of spaces for each indentation level in JSFX mode."
  :type 'integer
  :group 'jsfx
  :safe #'integerp)

(defcustom jsfx-auto-reload t
  "When non-nil, notify REAPER to reload JSFX after saving.
Requires jsfx-server.lua running in REAPER."
  :type 'boolean
  :group 'jsfx)

(defcustom jsfx-reaper-resource-path nil
  "Path to REAPER resource directory.
If nil, auto-detected from the buffer file path (looks for Effects/ ancestor)."
  :type '(choice (const nil) directory)
  :group 'jsfx)

(defcustom jsfx-ipc-timeout 2.0
  "Timeout in seconds for REAPER IPC commands."
  :type 'number
  :group 'jsfx)

;; ============================================================
;;; Syntax table
;; ============================================================

(defvar jsfx-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; C-style comments: // line and /* block */
    (modify-syntax-entry ?/ ". 124b" st)
    (modify-syntax-entry ?* ". 23" st)
    (modify-syntax-entry ?\n "> b" st)
    ;; Double-quoted strings
    (modify-syntax-entry ?\" "\"" st)
    ;; Parentheses (also code blocks in EEL2)
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    ;; Square brackets for memory indexing
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    ;; Underscore is word constituent (delay_buf, set_freq)
    (modify-syntax-entry ?_ "w" st)
    ;; Dot is symbol constituent (filt.process is one symbol, two words)
    (modify-syntax-entry ?. "_" st)
    ;; Operators as punctuation
    (modify-syntax-entry ?+ "." st)
    (modify-syntax-entry ?- "." st)
    (modify-syntax-entry ?= "." st)
    (modify-syntax-entry ?< "." st)
    (modify-syntax-entry ?> "." st)
    (modify-syntax-entry ?& "." st)
    (modify-syntax-entry ?| "." st)
    (modify-syntax-entry ?^ "." st)
    (modify-syntax-entry ?~ "." st)
    (modify-syntax-entry ?! "." st)
    (modify-syntax-entry ?% "." st)
    ;; $ is prefix for built-in constants ($pi, $e, $phi)
    (modify-syntax-entry ?$ "'" st)
    ;; # is prefix for string refs / char constants
    (modify-syntax-entry ?# "'" st)
    ;; : , ; ? are punctuation
    (modify-syntax-entry ?: "." st)
    (modify-syntax-entry ?, "." st)
    (modify-syntax-entry ?\; "." st)
    (modify-syntax-entry ?? "." st)
    st)
  "Syntax table for `jsfx-mode'.")

;; ============================================================
;;; Font-lock (syntax highlighting)
;; ============================================================

(defvar jsfx--section-re
  "^@\\(init\\|slider\\|block\\|sample\\|gfx\\|serialize\\)\\b"
  "Regexp matching JSFX section headers.")

(defvar jsfx--directive-re
  "^\\(desc\\|tags\\|in_pin\\|out_pin\\|options\\|filename\\):"
  "Regexp matching JSFX header directives.")

(defvar jsfx--import-re
  "^\\(import\\)\\s-"
  "Regexp matching JSFX import directive.")

(defvar jsfx--slider-def-re
  "^\\(slider[0-9]+\\):"
  "Regexp matching JSFX slider definitions.")

(defvar jsfx--keywords
  '("while" "loop" "function" "local" "instance" "global"
    "globals" "static" "this")
  "JSFX/EEL2 keywords.")

(defvar jsfx--builtins-math
  '("sin" "cos" "tan" "asin" "acos" "atan" "atan2"
    "exp" "log" "log10" "sqrt" "abs" "min" "max"
    "floor" "ceil" "pow" "sign" "rand" "srand"
    "invsqrt" "sqr")
  "JSFX math built-in functions.")

(defvar jsfx--builtins-memory
  '("memset" "memcpy" "freembuf" "mdct" "imdct"
    "mem_get_values" "mem_set_values"
    "mem_insert_shuffle" "mem_multiply_sum"
    "__memtop" "stack_push" "stack_pop" "stack_peek" "stack_exch")
  "JSFX memory built-in functions.")

(defvar jsfx--builtins-string
  '("strlen" "strcpy" "strcat" "strcmp" "stricmp"
    "strncpy" "strncat" "strncmp" "strnicmp"
    "sprintf" "printf" "match" "matchi"
    "str_getchar" "str_setchar" "str_setlen"
    "str_delsub" "str_insert")
  "JSFX string built-in functions.")

(defvar jsfx--builtins-fft
  '("fft" "ifft" "fft_real" "ifft_real"
    "fft_permute" "fft_ipermute" "convolve_c")
  "JSFX FFT built-in functions.")

(defvar jsfx--builtins-midi
  '("midisend" "midirecv" "midisyx"
    "midisend_buf" "midirecv_buf"
    "midisend_str" "midirecv_str")
  "JSFX MIDI built-in functions.")

(defvar jsfx--builtins-file
  '("file_open" "file_close" "file_rewind"
    "file_var" "file_mem" "file_avail"
    "file_riff" "file_text" "file_string")
  "JSFX file I/O built-in functions.")

(defvar jsfx--builtins-slider
  '("slider" "slider_next_chg" "slider_automate"
    "slider_show" "sliderchange")
  "JSFX slider built-in functions.")

(defvar jsfx--builtins-gfx
  '("gfx_lineto" "gfx_line" "gfx_rectto" "gfx_rect"
    "gfx_setpixel" "gfx_getpixel"
    "gfx_drawnumber" "gfx_drawchar" "gfx_drawstr"
    "gfx_measurestr" "gfx_measurechar"
    "gfx_setfont" "gfx_getfont"
    "gfx_set" "gfx_getchar"
    "gfx_circle" "gfx_arc" "gfx_roundrect" "gfx_triangle"
    "gfx_blit" "gfx_blitext" "gfx_blurto"
    "gfx_setimgdim" "gfx_getimgdim" "gfx_loadimg"
    "gfx_gradrect" "gfx_muladdrect"
    "gfx_deltablit" "gfx_transformblit"
    "gfx_setcursor"
    "gfx_clienttoscreen" "gfx_screentoclient")
  "JSFX graphics built-in functions.")

(defvar jsfx--builtins-atomic
  '("atomic_setifequal" "atomic_exch" "atomic_add"
    "atomic_set" "atomic_get")
  "JSFX atomic built-in functions.")

(defvar jsfx--system-vars
  '("srate" "samplesblock" "num_ch" "tempo" "play_state"
    "play_position" "beat_position" "ts_num" "ts_denom"
    "ext_noinit" "ext_nodenorm" "ext_midi_bus" "ext_tail_size"
    "pdc_delay" "pdc_bot_ch" "pdc_top_ch" "pdc_midi" "trigger")
  "JSFX system special variables.")

(defvar jsfx--gfx-vars
  '("gfx_r" "gfx_g" "gfx_b" "gfx_a" "gfx_a2"
    "gfx_w" "gfx_h" "gfx_x" "gfx_y"
    "gfx_mode" "gfx_clear" "gfx_dest" "gfx_texth"
    "gfx_ext_retina" "gfx_ext_flags"
    "mouse_x" "mouse_y" "mouse_cap" "mouse_wheel" "mouse_hwheel")
  "JSFX graphics special variables.")

(defvar jsfx-font-lock-keywords
  (let ((all-builtins (append jsfx--builtins-math
                              jsfx--builtins-memory
                              jsfx--builtins-string
                              jsfx--builtins-fft
                              jsfx--builtins-midi
                              jsfx--builtins-file
                              jsfx--builtins-slider
                              jsfx--builtins-gfx
                              jsfx--builtins-atomic)))
    `(
      ;; Section headers (@init, @slider, @block, @sample, @gfx, @serialize)
      (,jsfx--section-re . font-lock-preprocessor-face)
      ;; Header directives (desc:, tags:, in_pin:, etc.)
      (,jsfx--directive-re (1 font-lock-keyword-face))
      ;; Import directive
      (,jsfx--import-re (1 font-lock-keyword-face))
      ;; Slider definitions (slider1:, slider2:, ...)
      (,jsfx--slider-def-re (1 font-lock-keyword-face))
      ;; Built-in constants ($pi, $e, $phi, $x, $y, etc.)
      ("\\$[a-zA-Z_][a-zA-Z0-9_]*" . font-lock-constant-face)
      ;; Named string references (#name)
      ("#[a-zA-Z_][a-zA-Z0-9_]*" . font-lock-string-face)
      ;; Hex numbers
      ("\\b0[xX][0-9a-fA-F]+\\b" . font-lock-constant-face)
      ;; Keywords (while, loop, function, local, instance, global, ...)
      (,(concat "\\b" (regexp-opt jsfx--keywords t) "\\b")
       (1 font-lock-keyword-face))
      ;; Function definitions: function name(...)
      ("\\bfunction\\s-+\\([a-zA-Z_][a-zA-Z0-9_.]*\\)"
       (1 font-lock-function-name-face))
      ;; Built-in functions
      (,(concat "\\b" (regexp-opt all-builtins t) "\\b")
       (1 font-lock-builtin-face))
      ;; Audio sample variables (spl0..spl63)
      ("\\bspl[0-9]+" . font-lock-variable-name-face)
      ;; Slider variables (slider1..slider64)
      ("\\bslider[0-9]+" . font-lock-variable-name-face)
      ;; Register variables (reg00..reg31)
      ("\\breg[0-9]+" . font-lock-variable-name-face)
      ;; System special variables
      (,(concat "\\b" (regexp-opt jsfx--system-vars t) "\\b")
       (1 font-lock-variable-name-face))
      ;; GFX special variables
      (,(concat "\\b" (regexp-opt jsfx--gfx-vars t) "\\b")
       (1 font-lock-variable-name-face))
      ;; gmem[] shared memory
      ("\\bgmem\\b" . font-lock-variable-name-face)
      ;; Numeric literals (integer and float)
      ("\\b[0-9]+\\.?[0-9]*\\([eE][+-]?[0-9]+\\)?\\b" . font-lock-constant-face)
      ))
  "Font-lock keywords for `jsfx-mode'.")

;; ============================================================
;;; Indentation
;; ============================================================

(defun jsfx-indent-line ()
  "Indent the current line according to JSFX/EEL2 nesting rules.
Parentheses `()' serve as code blocks in EEL2."
  (interactive)
  (let ((indent (jsfx--calculate-indent)))
    (when indent
      (if (<= (current-column) (current-indentation))
          (indent-line-to indent)
        (save-excursion (indent-line-to indent))))))

(defun jsfx--calculate-indent ()
  "Calculate the proper indentation for the current line."
  (save-excursion
    (beginning-of-line)
    (cond
     ;; Section headers always at column 0
     ((looking-at "\\s-*@\\(init\\|slider\\|block\\|sample\\|gfx\\|serialize\\)\\b")
      0)
     ;; Header directives at column 0
     ((looking-at
       "\\s-*\\(desc\\|tags\\|in_pin\\|out_pin\\|import\\|options\\|filename\\)[: ]")
      0)
     ;; Slider definitions at column 0
     ((looking-at "\\s-*slider[0-9]+:")
      0)
     ;; General case: indent based on paren depth from syntax-ppss
     (t
      (let* ((ppss (syntax-ppss (line-beginning-position)))
             (depth (nth 0 ppss))
             (base-indent (* depth jsfx-indent-offset)))
        ;; If the line starts with a closing paren, reduce indent by one level
        (if (looking-at "\\s-*)")
            (max 0 (- base-indent jsfx-indent-offset))
          (max 0 base-indent)))))))

;; ============================================================
;;; Imenu support
;; ============================================================

(defvar jsfx-imenu-generic-expression
  '(("Sections" "^\\(@\\(?:init\\|slider\\|block\\|sample\\|gfx\\|serialize\\)\\)\\b" 1)
    ("Functions" "\\bfunction\\s-+\\([a-zA-Z_][a-zA-Z0-9_.]*\\)" 1))
  "Imenu patterns for navigating JSFX sections and function definitions.")

;; ============================================================
;;; Import parsing — extract functions from .jsfx-inc files
;; ============================================================

(defun jsfx--detect-reaper-resource-path ()
  "Detect REAPER resource path from current buffer's file path.
Looks for an `Effects' directory in the ancestry."
  (or jsfx-reaper-resource-path
      (when buffer-file-name
        (let ((path (file-name-directory buffer-file-name)))
          (when (string-match "\\(.+[\\/]\\)Effects[\\/]" path)
            (match-string 1 path))))))

(defun jsfx--effects-dir ()
  "Return the REAPER Effects directory path."
  (let ((resource (jsfx--detect-reaper-resource-path)))
    (when resource
      (expand-file-name "Effects/" resource))))

(defun jsfx--parse-imports ()
  "Parse import statements from current buffer.
Return list of resolved absolute file paths."
  (let ((effects-dir (jsfx--effects-dir))
        imports)
    (when effects-dir
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "^import\\s-+\\(.+\\)$" nil t)
          (let* ((import-path (string-trim (match-string-no-properties 1)))
                 (full-path (expand-file-name import-path effects-dir)))
            (when (file-exists-p full-path)
              (push full-path imports))))))
    (nreverse imports)))

(defun jsfx--extract-functions-from-file (file)
  "Extract function names and their short (method) names from FILE.
Returns a list of strings."
  (let (result)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward
              "\\bfunction\\s-+\\([a-zA-Z_][a-zA-Z0-9_.]*\\)\\s-*(" nil t)
        (let* ((full-name (match-string-no-properties 1))
               (dot-pos (string-match "\\.[^.]*$" full-name)))
          (push full-name result)
          ;; Also add the short method name (e.g. "process" from "lpf.process")
          (when dot-pos
            (push (substring full-name (1+ dot-pos)) result)))))
    (delete-dups (nreverse result))))

(defvar-local jsfx--import-cache nil
  "Cached completion candidates from imported files.")
(defvar-local jsfx--import-cache-tick nil
  "Buffer modification tick when import cache was built.")

(defun jsfx--import-completions ()
  "Return completion candidates from imported .jsfx-inc files.
Results are cached and invalidated when the buffer changes."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eq tick jsfx--import-cache-tick)
      (setq jsfx--import-cache
            (let (all-funcs)
              (dolist (file (jsfx--parse-imports))
                (setq all-funcs (append all-funcs
                                        (jsfx--extract-functions-from-file file))))
              (delete-dups all-funcs)))
      (setq jsfx--import-cache-tick tick))
    jsfx--import-cache))

;; ============================================================
;;; Slider variable parsing
;; ============================================================

(defvar-local jsfx--slider-cache nil
  "Cached slider variable names.")
(defvar-local jsfx--slider-cache-tick nil
  "Buffer modification tick when slider cache was built.")

(defun jsfx--slider-completions ()
  "Return named slider variables defined in the current file header.
Parses patterns like `slider1:varname=default<...>' or `slider1:default<...>'."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eq tick jsfx--slider-cache-tick)
      (setq jsfx--slider-cache
            (let (vars)
              (save-excursion
                (goto-char (point-min))
                (while (re-search-forward
                        "^slider[0-9]+:\\([a-zA-Z_][a-zA-Z0-9_]*\\)=" nil t)
                  (push (match-string-no-properties 1) vars)))
              (delete-dups (nreverse vars))))
      (setq jsfx--slider-cache-tick tick))
    jsfx--slider-cache))

;; ============================================================
;;; Completion at point
;; ============================================================

(defvar jsfx--builtin-cache nil
  "Cached list of all JSFX built-in identifiers for completion.")

(defun jsfx--builtin-completions ()
  "Return list of all JSFX built-in identifiers."
  (or jsfx--builtin-cache
      (setq jsfx--builtin-cache
            (append jsfx--keywords
                    jsfx--builtins-math
                    jsfx--builtins-memory
                    jsfx--builtins-string
                    jsfx--builtins-fft
                    jsfx--builtins-midi
                    jsfx--builtins-file
                    jsfx--builtins-slider
                    jsfx--builtins-gfx
                    jsfx--builtins-atomic
                    jsfx--system-vars
                    jsfx--gfx-vars))))

(defun jsfx-completion-at-point ()
  "Completion-at-point function for JSFX.
Combines built-in functions, imported functions, and slider variables."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (list (car bounds) (cdr bounds)
            (append (jsfx--builtin-completions)
                    (jsfx--import-completions)
                    (jsfx--slider-completions))
            :exclusive 'no))))

;; ============================================================
;;; REAPER IPC
;; ============================================================

(defconst jsfx--mode-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory where jsfx-mode.el is located.")

(defun jsfx--ipc-dir ()
  "Return the IPC directory path for REAPER communication."
  (expand-file-name "jsfx-ipc/" jsfx--mode-directory))

(defun jsfx--server-running-p ()
  "Return non-nil if jsfx-server.lua appears to be running in REAPER."
  (let ((ipc (jsfx--ipc-dir)))
    (when ipc
      (let ((status-file (expand-file-name "status.txt" ipc)))
        (when (file-exists-p status-file)
          ;; Check that the status file was updated within the last 5 seconds
          (let* ((attrs (file-attributes status-file))
                 (mtime (float-time (file-attribute-modification-time attrs)))
                 (age (- (float-time) mtime)))
            (< age 5.0)))))))

(defun jsfx--send-command (cmd &optional timeout)
  "Send CMD string to REAPER server, wait for response.
TIMEOUT defaults to `jsfx-ipc-timeout'.
Returns response string or nil on timeout."
  (let* ((timeout (or timeout jsfx-ipc-timeout))
         (ipc (jsfx--ipc-dir))
         (cmd-file (expand-file-name "cmd.txt" ipc))
         (resp-file (expand-file-name "resp.txt" ipc)))
    (unless ipc
      (error "Cannot determine REAPER resource path"))
    ;; Ensure IPC directory exists
    (make-directory ipc t)
    ;; Clear old response
    (when (file-exists-p resp-file)
      (delete-file resp-file))
    ;; Write command atomically (write .tmp then rename)
    (let ((tmp (concat cmd-file ".tmp")))
      (with-temp-file tmp
        (insert cmd "\n"))
      (rename-file tmp cmd-file t))
    ;; Poll for response
    (let ((start (float-time))
          result)
      (while (and (not result)
                  (< (- (float-time) start) timeout))
        (sleep-for 0.05)
        (when (file-exists-p resp-file)
          (setq result
                (with-temp-buffer
                  (insert-file-contents resp-file)
                  (buffer-string)))
          (delete-file resp-file)))
      result)))

;; ============================================================
;;; REAPER interactive commands
;; ============================================================

(defun jsfx-reaper-ping ()
  "Check if REAPER jsfx-server is running."
  (interactive)
  (let ((resp (jsfx--send-command "PING" 3.0)))
    (if resp
        (message "REAPER: %s" resp)
      (message "REAPER: no response (is jsfx-server.lua running?)"))))

(defun jsfx-reaper-reload ()
  "Force REAPER to reload the current JSFX file."
  (interactive)
  (let* ((name (file-name-sans-extension
                (file-name-nondirectory (or buffer-file-name ""))))
         (resp (jsfx--send-command (concat "RELOAD " name))))
    (if resp
        (message "Reload: %s" resp)
      (message "Reload: no response from REAPER"))))

(defun jsfx-reaper-fx-list ()
  "Show FX list on the selected track in REAPER."
  (interactive)
  (let ((resp (jsfx--send-command "FXLIST")))
    (if (and resp (string-prefix-p "OK" resp))
        (with-output-to-temp-buffer "*JSFX FX List*"
          (princ (substring resp 3)))
      (message "FX List: %s" (or resp "no response")))))

(defun jsfx-reaper-fx-params (fx-index)
  "Show parameters for FX at FX-INDEX on selected track."
  (interactive "nFX index: ")
  (let ((resp (jsfx--send-command (format "FXPARAMS %d" fx-index))))
    (if (and resp (string-prefix-p "OK" resp))
        (with-output-to-temp-buffer "*JSFX FX Params*"
          (princ "Idx\tName\tValue\tMin\tMax\tFormatted\n")
          (princ (make-string 60 ?-))
          (princ "\n")
          (princ (substring resp 3)))
      (message "FX Params: %s" (or resp "no response")))))

(defun jsfx-reaper-stop-server ()
  "Stop the jsfx-server running in REAPER."
  (interactive)
  (let ((resp (jsfx--send-command "STOP" 3.0)))
    (message "Stop: %s" (or resp "no response"))))

;; ============================================================
;;; After-save hook — auto-reload
;; ============================================================

(defun jsfx--after-save-hook ()
  "Notify REAPER to reload this JSFX after save."
  (when (and jsfx-auto-reload
             (jsfx--server-running-p))
    (let* ((name (file-name-sans-extension
                  (file-name-nondirectory buffer-file-name)))
           (resp (jsfx--send-command (concat "RELOAD " name) 1.0)))
      (when resp
        (message "REAPER reload: %s" resp)))))

;; ============================================================
;;; Mode definition
;; ============================================================

(defvar jsfx-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'jsfx-reaper-reload)
    (define-key map (kbd "C-c C-p") #'jsfx-reaper-ping)
    (define-key map (kbd "C-c C-l") #'jsfx-reaper-fx-list)
    map)
  "Keymap for `jsfx-mode'.")

;;;###autoload
(define-derived-mode jsfx-mode prog-mode "JSFX"
  "Major mode for editing REAPER JSFX (EEL2) audio effect files.

JSFX uses EEL2 scripting language with parenthesis-based code blocks.
This mode provides syntax highlighting, automatic indentation,
context-aware completion, and optional REAPER integration.

Key bindings:
\\<jsfx-mode-map>
  \\[jsfx-reaper-reload]  Force reload in REAPER
  \\[jsfx-reaper-ping]    Ping REAPER server
  \\[jsfx-reaper-fx-list] Show FX list

\\{jsfx-mode-map}"
  :syntax-table jsfx-mode-syntax-table
  :group 'jsfx

  ;; Comment style
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "\\(?://+\\|/\\*+\\)\\s-*")

  ;; Font-lock (case-insensitive, since EEL2 identifiers are case-insensitive)
  (setq-local font-lock-defaults '(jsfx-font-lock-keywords nil t))

  ;; Indentation
  (setq-local indent-line-function #'jsfx-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width jsfx-indent-offset)
  (setq-local electric-indent-chars '(?\) ?\;))

  ;; Imenu
  (setq-local imenu-generic-expression jsfx-imenu-generic-expression)

  ;; Completion
  (add-hook 'completion-at-point-functions #'jsfx-completion-at-point nil t)

  ;; Auto-reload on save
  (add-hook 'after-save-hook #'jsfx--after-save-hook nil t)

  ;; Paragraph handling (sections start new paragraphs)
  (setq-local paragraph-start (concat "\\|@\\|" page-delimiter))
  (setq-local paragraph-separate paragraph-start))

;; ============================================================
;;; File associations
;; ============================================================

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.jsfx\\'" . jsfx-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.jsfx-inc\\'" . jsfx-mode))

(provide 'jsfx-mode)
;;; jsfx-mode.el ends here
