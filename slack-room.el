;;; slack-room.el --- slack generic room interface    -*- lexical-binding: t; -*-

;; Copyright (C) 2015  南優也

;; Author: 南優也 <yuyaminami@minamiyuunari-no-MacBook-Pro.local>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'eieio)
(require 'lui)
(require 'slack-request)
(require 'slack-message)
(require 'slack-pinned-item)

(defvar slack-buffer-function)
(defconst slack-room-pins-list-url "https://slack.com/api/pins.list")

(defclass slack-room ()
  ((name :initarg :name :type string)
   (id :initarg :id)
   (created :initarg :created)
   (has-pins :initarg :has_pins)
   (last-read :initarg :last_read :type string :initform "0")
   (latest :initarg :latest)
   (oldest :initarg :oldest)
   (unread-count :initarg :unread_count)
   (unread-count-display :initarg :unread_count_display :initform 0 :type integer)
   (messages :initarg :messages :initform ())
   (team-id :initarg :team-id)
   (buffer :initform nil :type (or null slack-buffer))
   (thread-message-buffers :initform '() :type list)))

(defgeneric slack-room-name (room))
(defgeneric slack-room-history (room team &optional oldest after-success sync))
(defgeneric slack-room-update-mark-url (room))

(defun slack-room-create (payload team class)
  (cl-labels
      ((prepare (p)
                (plist-put p :members
                           (append (plist-get p :members) nil))
                (plist-put p :team-id (oref team id))
                p))
    (let* ((attributes (slack-collect-slots class (prepare payload)))
           (room (apply #'make-instance class attributes)))
      (oset room latest (slack-message-create (plist-get payload :latest) team :room room))
      room)))

(defmethod slack-room-subscribedp ((_room slack-room) _team)
  nil)

(defmethod slack-room-buffer-name ((room slack-room))
  (concat "*Slack*"
          " : "
          (slack-room-display-name room)))

(cl-defmacro slack-select-from-list ((alist prompt &key initial) &body body)
  "Bind candidates from selected."
  (declare (indent 2) (debug t))
  (let ((key (cl-gensym)))
    `(let* ((,key (let ((completion-ignore-case t))
                    (funcall slack-completing-read-function (format "%s" ,prompt)
                             ,alist nil t ,initial)))
            (selected (cdr (cl-assoc ,key ,alist :test #'string=))))
       ,@body
       selected)))

(defun slack-room-hiddenp (room)
  (or (not (slack-room-member-p room))
      (slack-room-archived-p room)
      (not (slack-room-open-p room))))

(defun slack-room-select (rooms)
  (let* ((alist (slack-room-names
                 rooms #'(lambda (rs) (cl-remove-if #'slack-room-hiddenp rs)))))
    (slack-select-from-list (alist "Select Channel: "))))

(cl-defun slack-room-list-update (url success team &key (sync t))
  (slack-request
   (slack-request-create
    url
    team
    :success success)))

(defun slack-room-find-message (room ts)
  (cl-find-if #'(lambda (m) (string= ts (oref m ts)))
              (oref room messages)
              :from-end t))

(defun slack-room-find-thread-parent (room thread-message)
  (slack-room-find-message room (oref thread-message thread-ts)))

(defmethod slack-message-thread ((this slack-message) _room)
  (oref this thread))

(defmethod slack-message-thread ((this slack-reply-broadcast-message) room)
  (let ((message (slack-room-find-message room
                                          (or (oref this broadcast-thread-ts)
                                              (oref this thread-ts)))))
    (slack-message-thread message room)))

(defun slack-room-find-thread (room ts)
  (let ((message (slack-room-find-message room ts)))
    (when message
      (slack-message-thread message room))))

(defmethod slack-room-team ((room slack-room))
  (slack-team-find (oref room team-id)))

(defmethod slack-room-display-name ((room slack-room))
  (let ((room-name (slack-room-name room)))
    (if slack-display-team-name
        (format "%s - %s"
                (oref (slack-room-team room) name)
                room-name)
      room-name)))

(defmethod slack-room-label-prefix ((_room slack-room))
  "  ")

(defmethod slack-room-unread-count-str ((room slack-room))
  (with-slots (unread-count-display) room
    (if (< 0 unread-count-display)
        (concat " ("
                (number-to-string unread-count-display)
                ")")
      "")))

(defmethod slack-room-label ((room slack-room))
  (format "%s%s%s"
          (slack-room-label-prefix room)
          (slack-room-display-name room)
          (slack-room-unread-count-str room)))

(defmacro slack-room-names (rooms &optional filter)
  `(cl-labels
       ((latest-ts (room)
                   (with-slots (latest) room
                     (if latest (oref latest ts) "0")))
        (sort-rooms (rooms)
                    (nreverse
                     (cl-sort rooms #'string<
                              :key #'(lambda (name-with-room) (latest-ts (cdr name-with-room)))))))
     (sort-rooms
      (cl-loop for room in (if ,filter
                               (funcall ,filter ,rooms)
                             ,rooms)
               collect (cons (slack-room-label room) room)))))

(defmethod slack-room-name ((room slack-room))
  (oref room name))

(defmethod slack-room-update-last-read-p ((room slack-room) ts)
  (not (string> (oref room last-read) ts)))

(defmethod slack-room-update-last-read ((room slack-room) msg)
  (if (slack-room-update-last-read-p room (oref msg ts))
      (oset room last-read (oref msg ts))))


(defmethod slack-room-latest-messages ((room slack-room) messages)
  (with-slots (last-read) room
    (cl-remove-if #'(lambda (m)
                      (or (string< (oref m ts) last-read)
                          (string= (oref m ts) last-read)))
                  messages)))

(defun slack-room-sort-messages (messages)
  (cl-sort messages
           #'string<
           :key #'(lambda (m) (oref m ts))))

(defun slack-room-reject-thread-message (messages)
  (cl-remove-if #'(lambda (m) (and (not (eq (eieio-object-class-name m)
                                            'slack-reply-broadcast-message))
                                   (slack-thread-message-p m)))
                messages))

(defmethod slack-room-sorted-messages ((room slack-room))
  (with-slots (messages) room
    (slack-room-sort-messages (copy-sequence messages))))

(defmethod slack-room-set-prev-messages ((room slack-room) prev-messages)
  (slack-room-set-messages
   room
   (cl-delete-duplicates (append (oref room messages)
                                 prev-messages)
                         :test #'slack-message-equal)))

(defmethod slack-room-update-latest ((room slack-room) message)
  (with-slots (latest) room
    (if (or (null latest)
            (string< (oref latest ts) (oref message ts)))
        (setq latest message))))

(defmethod slack-room-set-oldest ((room slack-room) sorted-messages)
  (let ((oldest (and (slot-boundp room 'oldest) (oref room oldest)))
        (maybe-oldest (car sorted-messages)))
    (if oldest
        (when (string< (oref maybe-oldest ts) (oref oldest ts))
          (oset room oldest maybe-oldest))
      (oset room oldest maybe-oldest))))

(defmethod slack-room-push-message ((room slack-room) message)
  (with-slots (messages) room
    (slack-room-set-oldest room (list message))
    (setq messages
          (cl-remove-if #'(lambda (n) (slack-message-equal message n))
                        messages))
    (push message messages)))

(defmethod slack-room-set-messages ((room slack-room) messages)
  (let* ((sorted (slack-room-sort-messages messages))
         (oldest (car sorted))
         (latest (car (last sorted))))
    (oset room oldest oldest)
    (oset room messages sorted)
    (oset room latest latest)))

(defmethod slack-room-prev-messages ((room slack-room) from)
  (with-slots (messages) room
    (cl-remove-if #'(lambda (m)
                      (or (string< from (oref m ts))
                          (string= from (oref m ts))))
                  (slack-room-sort-messages (copy-sequence messages)))))

(defmethod slack-room-update-mark ((room slack-room) team ts)
  (cl-labels ((on-update-mark (&key data &allow-other-keys)
                              (slack-request-handle-error
                               (data "slack-room-update-mark"))))
    (with-slots (id) room
      (slack-request
       (slack-request-create
        (slack-room-update-mark-url room)
        team
        :type "POST"
        :params (list (cons "channel"  id)
                      (cons "ts"  ts))
        :success #'on-update-mark)))))

(defun slack-room-pins-list ()
  (interactive)
  (slack-if-let* ((buf slack-current-buffer))
      (slack-buffer-display-pins-list buf)))

(defun slack-select-rooms ()
  (interactive)
  (let* ((team (slack-team-select))
         (room (slack-room-select
                (cl-loop for team in (list team)
                         append (with-slots (groups ims channels) team
                                  (append ims groups channels))))))
    (slack-room-display room team)))

(defun slack-create-room (url team success)
  (slack-request
   (slack-request-create
    url
    team
    :type "POST"
    :params (list (cons "name" (read-from-minibuffer "Name: ")))
    :success success)))

(defun slack-room-rename (url room-alist-func)
  (cl-labels
      ((on-rename-success (&key data &allow-other-keys)
                          (slack-request-handle-error
                           (data "slack-room-rename"))))
    (let* ((team (slack-team-select))
           (room-alist (funcall room-alist-func team))
           (room (slack-select-from-list
                     (room-alist "Select Channel: ")))
           (name (read-from-minibuffer "New Name: ")))
      (slack-request
       (slack-request-create
        url
        team
        :params (list (cons "channel" (oref room id))
                      (cons "name" name))
        :success #'on-rename-success)))))

(defmacro slack-current-room-or-select (room-alist-func &optional select)
  `(if (and (not ,select)
            (bound-and-true-p slack-current-buffer)
            (slot-boundp slack-current-buffer 'room))
       (oref slack-current-buffer room)
     (let* ((room-alist (funcall ,room-alist-func)))
       (slack-select-from-list
           (room-alist "Select Channel: ")))))

(defmacro slack-room-invite (url room-alist-func)
  `(cl-labels
       ((on-group-invite (&key data &allow-other-keys)
                         (slack-request-handle-error
                          (data "slack-room-invite")
                          (if (plist-get data :already_in_group)
                              (message "User already in group")
                            (message "Invited!")))))
     (let* ((team (slack-team-select))
            (room (slack-current-room-or-select
                   #'(lambda ()
                       (funcall ,room-alist-func team
                                #'(lambda (rooms)
                                    (cl-remove-if #'slack-room-archived-p
                                                  rooms))))))
            (user-id (plist-get (slack-select-from-list
                                    ((slack-user-names team)
                                     "Select User: ")) :id)))
       (slack-request
        (slack-request-create
         ,url
         team
         :params (list (cons "channel" (oref room id))
                       (cons "user" user-id))
         :success #'on-group-invite)))))

(defmethod slack-room-member-p ((_room slack-room)) t)

(defmethod slack-room-archived-p ((_room slack-room)) nil)

(defmethod slack-room-open-p ((_room slack-room)) t)

(defmethod slack-room-equal-p ((room slack-room) other)
  (string= (oref room id) (oref other id)))

(defun slack-room-deleted (id team)
  (let ((room (slack-room-find id team)))
    (cond
     ((object-of-class-p room 'slack-channel)
      (with-slots (channels) team
        (setq channels (cl-delete-if #'(lambda (c) (slack-room-equal-p room c))
                                     channels)))
      (message "Channel: %s deleted"
               (slack-room-display-name room))))))

(cl-defun slack-room-request-with-id (url id team success)
  (slack-request
   (slack-request-create
    url
    team
    :params (list (cons "channel" id))
    :success success)))

(defmethod slack-room-reset-last-read ((room slack-room))
  (oset room last-read "0"))

(defmethod slack-room-inc-unread-count ((room slack-room))
  (cl-incf (oref room unread-count-display)))

(defun slack-room-find-by-name (name team)
  (cl-labels
      ((find-by-name (rooms name)
                     (cl-find-if #'(lambda (e) (string= name
                                                        (slack-room-name e)))
                                 rooms)))
    (or (find-by-name (oref team groups) name)
        (find-by-name (oref team channels) name)
        (find-by-name (oref team ims) name))))

(defmethod slack-room-info-request-params ((room slack-room))
  (list (cons "channel" (oref room id))))

(defmethod slack-room-info-request ((room slack-room) team)
  (cl-labels
      ((on-success
        (&key data &allow-other-keys)
        (slack-request-handle-error
         (data "slack-room-info-request"
               #'(lambda (e)
                   (if (not (string= e "user_disabled"))
                       (message "Failed to request slack-room-info-request: %s" e))))
         (slack-room-update-info room data team))))
    (slack-request
     (slack-request-create
      (slack-room-get-info-url room)
      team
      :params (slack-room-info-request-params room)
      :success #'on-success))))

(defmethod slack-room-get-members ((room slack-room))
  (oref room members))

(defun slack-room-user-select ()
  (interactive)
  (slack-if-let* ((buf slack-current-buffer))
      (slack-buffer-display-user-profile buf)))

(defun slack-select-unread-rooms ()
  (interactive)
  (let* ((team (slack-team-select))
         (room (slack-room-select
                (cl-loop for team in (list team)
                         append (with-slots (groups ims channels) team
                                  (cl-remove-if
                                   #'(lambda (room)
                                       (not (< 0 (oref room
                                                       unread-count-display))))
                                   (append ims groups channels)))))))
    (slack-room-display room team)))

(defmethod slack-user-find ((room slack-room) team)
  (slack-user--find (oref room user) team))

(defun slack-room-find-file-comment-message (room comment-id)
  (let ((messages (oref room messages)))
    (cl-find-if #'(lambda (m) (and
                               (object-of-class-p m 'slack-file-message)
                               (or
                                (and (slack-file-share-message-p m)
                                     (oref (oref m file) initial-comment)
                                     (string= comment-id
                                              (oref (oref
                                                     (oref m file)
                                                     initial-comment)
                                                    id)))
                                (and
                                 (slot-exists-p m 'comment)
                                 (slot-boundp m 'comment)
                                 (string= comment-id (oref (oref m comment) id))))))
                messages)))

(defun slack-room-find-file-share-message (room file-id)
  (let ((messages (oref room messages)))
    (cl-find-if #'(lambda (m) (and (slack-file-share-message-p m)
                                   (slot-exists-p m 'file)
                                   (slot-boundp m 'file)
                                   (string= file-id (oref (oref m file) id))))
                messages)))

(defun slack-room-display (room team)
  (cl-labels
      ((open (buf)
             (slack-buffer-display buf)))
    (let* ((buf (slack-buffer-find (or (and (eq (eieio-object-class-name room)
                                                'slack-file-room)
                                            'slack-file-list-buffer)
                                       'slack-message-buffer)
                                   room team)))
      (if buf (open buf)
        (slack-room-history-request
         room team
         :after-success #'(lambda ()
                            (open (slack-create-message-buffer room team))))))))

(defmethod slack-room-update-buffer ((this slack-room) team message replace)
  (slack-if-let* ((buffer (slack-buffer-find 'slack-message-buffer this team)))
      (slack-buffer-update buffer message :replace replace)
    (slack-room-inc-unread-count this)
    (and slack-buffer-create-on-notify
         (slack-room-history-request
          this team
          :after-success #'(lambda ()
                             (tracking-add-buffer
                              (slack-buffer-buffer
                               (slack-create-message-buffer this team))))))))

(cl-defmethod slack-room-history-request ((room slack-room) team &key oldest after-success async)
  (cl-labels
      ((on-request-update
        (&key data &allow-other-keys)
        (slack-request-handle-error
         (data "slack-room-request-update")
         (let* ((datum (plist-get data :messages))
                (messages
                 (cl-loop for data in datum
                          collect (slack-message-create data team :room room))))
           (if oldest (slack-room-set-prev-messages room messages)
             (slack-room-set-messages room messages)
             (slack-room-reset-last-read room))
           (if (and after-success (functionp after-success))
               (funcall after-success))))))
    (slack-request
     (slack-request-create
      (slack-room-history-url room)
      team
      :params (list (cons "channel" (oref room id))
                    (if oldest (cons "latest" oldest)))
      :success #'on-request-update))))

(provide 'slack-room)
;;; slack-room.el ends here
