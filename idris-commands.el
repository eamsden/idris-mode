;;; idris-commands.el --- Commands for Emacs passed to idris -*- lexical-binding: t -*-

;; Copyright (C) 2013 Hannes Mehnert

;; Author: Hannes Mehnert <hannes@mehnert.org>

;; License:
;; Inspiration is taken from SLIME/DIME (http://common-lisp.net/project/slime/) (https://github.com/dylan-lang/dylan-mode)
;; Therefore license is GPL

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING. If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

(require 'idris-core)
(require 'idris-settings)
(require 'inferior-idris)
(require 'idris-repl)
(require 'idris-warnings)
(require 'idris-compat)
(require 'idris-info)
(require 'idris-log)
(require 'idris-warnings-tree)
(require 'popup)
(require 'cl-lib)

(defvar-local idris-buffer-dirty-p t
  "An Idris buffer is dirty if there have been modifications since it was last loaded")

(defvar idris-currently-loaded-buffer nil
  "The buffer currently loaded by the running Idris")

(defun idris-make-dirty ()
  (setq idris-buffer-dirty-p t))

(defun idris-make-clean ()
  (setq idris-buffer-dirty-p nil))

(defun idris-current-buffer-dirty-p ()
  "Check whether the current buffer's most recent version is loaded"
  (or idris-buffer-dirty-p
      (not (equal (current-buffer)
                  idris-currently-loaded-buffer))))


(defun idris-ensure-process-and-repl-buffer ()
  "Ensures that an Idris process is running and the Idris REPL buffer exists"
  (idris-repl-buffer)
  (idris-run)
  (with-current-buffer (idris-repl-buffer)
    (idris-mark-output-start)))

(defun idris-switch-working-directory (new-working-directory)
  (unless (string= idris-process-current-working-directory new-working-directory)
    (idris-ensure-process-and-repl-buffer)
    (idris-eval `(:interpret ,(concat ":cd " new-working-directory)))
    (setq idris-process-current-working-directory new-working-directory)))

(defun idris-load-file ()
  "Pass the current buffer's file to the inferior Idris process."
  (interactive)
  (save-buffer)
  (idris-ensure-process-and-repl-buffer)
  (if (buffer-file-name)
      (when (idris-current-buffer-dirty-p)
        (idris-warning-reset-all)
        (let ((fn (buffer-file-name)))
          (idris-switch-working-directory (file-name-directory fn))
          (setq idris-currently-loaded-buffer nil)
          (idris-eval-async `(:load-file ,(file-name-nondirectory fn))
                          (lambda (result)
                            (idris-make-clean)
                            (setq idris-currently-loaded-buffer (current-buffer))
                            (when (member 'warnings-tree idris-warnings-printing)
                              (idris-list-compiler-notes))
                            (message result))
                          (lambda (_condition)
                            (when (member 'warnings-tree idris-warnings-printing)
                              (idris-list-compiler-notes)
                              (pop-to-buffer (idris-buffer-name :notes)))))))
    (error "Cannot find file for current buffer")))

(defun idris-view-compiler-log ()
  "Jump to the log buffer, if it is open"
  (interactive)
  (let ((buffer (get-buffer idris-log-buffer-name)))
    (if buffer
        (pop-to-buffer buffer)
      (message "No Idris compiler log is currently open"))))

(defun idris-load-file-sync ()
  "Pass the current buffer's file synchronously to the inferior Idris process."
  (save-buffer)
  (idris-ensure-process-and-repl-buffer)
  (if (buffer-file-name)
      (when (idris-current-buffer-dirty-p)
        (idris-warning-reset-all)
        (let ((fn (buffer-file-name)))
          (idris-switch-working-directory (file-name-directory fn))
          (setq idris-currently-loaded-buffer nil)
          (idris-eval `(:load-file ,(file-name-nondirectory fn)))
          (setq idris-currently-loaded-buffer (current-buffer)))
        (idris-make-clean))
    (error "Cannot find file for current buffer")))


(defun idris-get-line-num ()
  "Get the current line number"
  (save-restriction
    (widen)
    (save-excursion
      (beginning-of-line)
      (1+ (count-lines 1 (point))))))

(defun idris-thing-at-point ()
  "Return the line number and name at point"
  (let ((name (symbol-at-point))
        (line (idris-get-line-num)))
    (if name
        (cons (substring-no-properties (symbol-name name)) line)
      (error "Nothing identifiable under point"))))

(defun idris-type-at-point (thing)
  "Display the type of the name at point, considered as a global variable"
  (interactive "P")
  (let ((name (if thing (read-string "Check: ")
                (car (idris-thing-at-point)))))
    (when name
      (if thing (idris-ensure-process-and-repl-buffer) (idris-load-file-sync))
      (let* ((ty (idris-eval `(:type-of ,name)))
             (result (car ty))
             (formatting (cdr ty)))
      (idris-show-info (format "%s" result) formatting)))))

(defun idris-case-split ()
  "Case split the pattern variable at point"
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:case-split ,(cdr what) ,(car what))))))
        (delete-region (line-beginning-position) (line-end-position))
        (idris-insert-or-expand (substring result 0 (1- (length result))))))))

(defun idris-add-clause (proof)
  "Add clauses to the declaration at point"
  (interactive "P")
  (let ((what (idris-thing-at-point))
        (command (if proof :add-proof-clause :add-clause)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(,command ,(cdr what) ,(car what))))))
        (end-of-line)
        (insert "\n")
        (idris-insert-or-expand result)))))

(defun idris-add-missing ()
  "Add missing cases"
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:add-missing ,(cdr what) ,(car what))))))
        (forward-line 1)
        (idris-insert-or-expand result)))))

(defun idris-make-with-block ()
  "Add with block"
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:make-with ,(cdr what) ,(car what))))))
        (beginning-of-line)
        (kill-line)
        (idris-insert-or-expand result)))))

(defun idris-insert-or-expand (str)
  "If yasnippet is loaded, use it to expand Idris compiler output, otherwise fall back on inserting the output"
  (if (and (fboundp 'yas-expand-snippet) idris-use-yasnippet-expansions)
      (let ((snippet (idris-metavar-to-snippet str)))
        (message snippet)
        (yas-expand-snippet snippet nil nil '((yas-indent-line nil))))
    (insert str)))

(defun idris-metavar-to-snippet (str)
  "Replace metavariables with yasnippet snippets"
  (let ((n 0))
    (cl-flet ((to-snippet-param (metavar)
                 (cl-incf n)
                 (if (string= metavar "(_)")
                     (format "(${%s:_})" n)
                   (format "${%s:%s}" n metavar))))
      (replace-regexp-in-string "\\?[a-zA-Z0-9_]+\\|(_)" #'to-snippet-param str))))

(defun idris-proof-search (hints)
  "Invoke the proof search"
  (interactive "P")
  (let ((hints (if hints
                   (split-string (read-string "Hints: ") "[^a-zA-Z0-9']")
                 '()))
        (what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:proof-search ,(cdr what) ,(car what) ,hints)))))
        (save-excursion
          (let ((start (progn (search-backward "?") (point)))
                (end (progn (forward-char) (search-forward-regexp "[^a-zA-Z0-9_']") (backward-char) (point))))
            (delete-region start end))
          (idris-insert-or-expand result))))))

(defun idris-is-ident-char-p (ch)
  (or (and (<= ?a ch) (<= ch ?z))
      (and (<= ?A ch) (<= ch ?Z))
      (and (<= ?0 ch) (<= ch ?9))
      (= ch ?_)))

(defun idris-identifier-backwards-from-point ()
  (let ((identifier-start nil)
        (identifier-end (point))
        (last-char (char-before))
        (failure (list nil nil nil)))
    (if (idris-is-ident-char-p last-char)
        (progn
          (save-excursion
            (while (idris-is-ident-char-p (char-before))
              (backward-char))
            (setq identifier-start (point)))
          (if identifier-start
              (list (buffer-substring-no-properties identifier-start identifier-end)
                    identifier-start
                    identifier-end)
            failure))
      failure)))

(defun idris-complete-symbol-at-point ()
  "Attempt to complete the symbol at point as a global variable.

This function does not attempt to load the buffer if it's not
already loaded, as a buffer awaiting completion is probably not
type-correct, so loading will fail."
  (if (not idris-process)
      nil
    (cl-destructuring-bind (identifier start end) (idris-identifier-backwards-from-point)
      (when identifier
        (let ((result (car (idris-eval `(:repl-completions ,identifier)))))
          (cl-destructuring-bind (completions _partial) result
            (if (null completions)
                nil
              (list start end completions))))))))

(defun idris-insert-bottom ()
  "Insert _|_ at point"
  (interactive)
  (insert "_|_"))

(defun idris-refine-metavar ()
  "Select an identifier to refine a metavariable"
  (interactive)
  (idris-load-file-sync)
  (let* ((thing (car (idris-thing-at-point)))
         (result (idris-eval `(:compatible-identifiers ,thing)))
         (selected (substring-no-properties (popup-menu* result :isearch 't)))
         (newexpr (idris-eval `(:make-refined-expression ,selected))))
    (beginning-of-line)
    (if (search-forward (concat "?" thing) nil t)
        (replace-match newexpr t t)
        (error "metavariable %s seems to have vanished." thing))
    (idris-load-file-sync)))

(defun idris-refine-metavar-complete ()
  "Select an identifier to refine a metavariable"
  (interactive)
  (idris-load-file-sync)
  (let* ((thing (car (idris-thing-at-point)))
         (result (idris-eval `(:complete-compatible-identifiers ,thing)))
         (selected (substring-no-properties (popup-menu* result :isearch 't)))
         (newexpr (idris-eval `(:make-refined-expression ,selected))))
    (beginning-of-line)
    (if (search-forward (concat "?" thing) nil t)
        (replace-match newexpr t t)
        (error "metavariable %s seems to have vanished." thing))
    (idris-load-file-sync)))

(defun idris-refine-metavar-recursive ()
  "Select an identifier to refine a metavariable"
  (interactive)
  (idris-load-file-sync)
  (defun idris-refine-metavar-recursive-step (thing response)
    (if (eq (car response) :identifier-list)
      (let* ((selected (substring-no-properties (popup-menu* (cadr response))))
             (newresponse (idris-eval `(:choose-identifier ,selected))))
        (idris-refine-metavar-recursive-step thing newresponse))
      (progn
        (beginning-of-line)
        (if (search-forward (concat "?" thing) nil t)
            (replace-match (cadr response) t t)
            (error "metavariable %s seems to have vanished." thing))
        (idris-load-file-sync))))

  (let* ((thing (car (idris-thing-at-point)))
         (result (idris-eval `(:compatible-identifiers-recursive ,thing))))
    (idris-refine-metavar-recursive-step thing result)))

(defun idris-kill-buffers ()
  (idris-warning-reset-all)
  (setq idris-currently-loaded-buffer nil)
  ; not killing :events since it it tremendously useful for debuging
  (let ((bufs (list :repl :proof-obligations :proof-shell :proof-script :log :info :notes)))
    (dolist (b bufs) (idris-kill-buffer b))))

(defun idris-quit ()
  (interactive)
  (let* ((pbufname (idris-buffer-name :process))
         (pbuf (get-buffer pbufname)))
    (if pbuf
        (progn
          (kill-buffer pbuf)
          (unless (get-buffer pbufname) (idris-kill-buffers))
          (setq idris-rex-continuations '()))
      (idris-kill-buffers))))

(provide 'idris-commands)
