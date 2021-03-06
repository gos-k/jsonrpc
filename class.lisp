(in-package #:cl-user)
(defpackage #:jsonrpc/class
  (:use #:cl)
  (:import-from #:jsonrpc/mapper
                #:exposable
                #:expose
                #:register-method
                #:clear-methods
                #:dispatch)
  (:import-from #:jsonrpc/transport/interface
                #:transport
                #:transport-connection
                #:transport-threads
                #:start-server
                #:start-client
                #:receive-message-using-transport)
  (:import-from #:jsonrpc/connection
                #:*connection*
                #:set-callback-for-id
                #:add-message-to-outbox)
  (:import-from #:jsonrpc/request-response
                #:make-request
                #:response-error
                #:response-error-code
                #:response-error-message
                #:response-result)
  (:import-from #:jsonrpc/errors
                #:jsonrpc-callback-error
                #:jsonrpc-timeout)
  (:import-from #:jsonrpc/utils
                #:find-mode-class
                #:make-id)
  (:import-from #:bordeaux-threads
                #:*default-special-bindings*
                #:destroy-thread)
  (:import-from #:event-emitter
                #:on
                #:emit
                #:event-emitter)
  (:import-from #:alexandria
                #:remove-from-plist)
  (:import-from #:chanl)
  (:import-from #:trivial-timeout
                #:with-timeout
                #:timeout-error)
  (:export #:*default-timeout*
           #:client
           #:server
           #:jsonrpc-transport
           #:expose
           #:register-method
           #:clear-methods
           #:dispatch
           #:server-listen
           #:client-connect
           #:client-disconnect
           #:send-message
           #:receive-message
           #:call-to
           #:call-async-to
           #:notify-to
           #:call
           #:call-async
           #:notify
           #:notify-async
           #:broadcast
           #:multicall-async))
(in-package #:jsonrpc/class)

(defvar *default-timeout* 60)

(defclass jsonrpc (event-emitter exposable)
  ((transport :type (or null transport)
              :initarg :transport
              :initform nil
              :accessor jsonrpc-transport)))

(defun ensure-connected (jsonrpc)
  (check-type jsonrpc jsonrpc)
  (unless (jsonrpc-transport jsonrpc)
    (error 'jsonrpc-error :message (format nil "Connection isn't established yet for ~A" jsonrpc))))

(defclass client (jsonrpc) ())

(defclass server (jsonrpc)
  ((client-connections :initform '()
                       :accessor server-client-connections)
   (%lock :initform (bt:make-lock "client-connections-lock"))))

(defun server-listen (server &rest initargs &key mode &allow-other-keys)
  (let* ((class (find-mode-class mode))
         (initargs (remove-from-plist initargs :mode))
         (bt:*default-special-bindings* `((*standard-output* . ,*standard-output*)
                                          (*error-output* . ,*error-output*)) ))
    (unless class
      (error 'jsonrpc-error :message (format nil "Unknown mode ~A" mode)))
    (let ((transport (apply #'make-instance class
                            :message-callback
                            (lambda (message)
                              (dispatch server message))
                            initargs)))
      (setf (jsonrpc-transport server) transport)

      (on :open transport
          (lambda (connection)
            (with-slots (%lock client-connections) server
              (on :close connection
                  (lambda ()
                    (bt:with-lock-held (%lock)
                      (setf client-connections
                            (delete connection client-connections)))))
              (bt:with-lock-held (%lock)
                (push connection client-connections)))
            (emit :open server connection)))

      (start-server transport)))
  server)

(defun client-connect (client &rest initargs &key mode &allow-other-keys)
  (let* ((class (find-mode-class mode))
         (initargs (remove-from-plist initargs :mode))
         (bt:*default-special-bindings* `((*standard-output* . ,*standard-output*)
                                          (*error-output* . ,*error-output*)) ))
    (unless class
      (error 'jsonrpc-error :message (format nil "Unknown mode ~A" mode)))
    (let ((transport (apply #'make-instance class
                            :message-callback
                            (lambda (message)
                              (dispatch client message))
                            initargs)))
      (setf (jsonrpc-transport client) transport)

      (on :open transport
          (lambda (connection)
            (emit :open client connection)))

      (start-client transport)))
  client)

(defun client-disconnect (client)
  (ensure-connected client)
  (let ((transport (jsonrpc-transport client)))
    (mapc #'bt:destroy-thread (transport-threads transport))
    (setf (transport-threads transport) '())
    (setf (transport-connection transport) nil))
  (emit :close client)
  (values))

(defgeneric send-message (to connection message)
  (:method (to connection message)
    (declare (ignore to))
    (add-message-to-outbox connection message)))

(defun receive-message (from connection)
  (ensure-connected from)
  (receive-message-using-transport (jsonrpc-transport from) connection))

(deftype jsonrpc-params () '(or list array hash-table structure-object standard-object condition))

(defun call-async-to (from to method &optional params callback error-callback)
  (check-type params jsonrpc-params)
  (let ((id (make-id)))
    (set-callback-for-id to
                         id
                         (lambda (response)
                           (if (response-error response)
                               (and error-callback
                                    (funcall error-callback
                                             (response-error-message response)
                                             (response-error-code response)))
                               (and callback
                                    (funcall callback (response-result response))))))

    (send-message from
                  to
                  (make-request :id id
                                :method method
                                :params params))

    (values)))

(defun call-to (from to method &optional params &rest options)
  (destructuring-bind (&key (timeout *default-timeout*)) options
    (let ((channel (make-instance 'chanl:unbounded-channel)))
      (call-async-to from to
                     method
                     params
                     (lambda (res)
                       (chanl:send channel res))
                     (lambda (message code)
                       (chanl:send channel (make-condition 'jsonrpc-callback-error
                                                           :message message
                                                           :code code))))
      (let ((result (handler-case (with-timeout (timeout)
                                    (chanl:recv channel))
                      (timeout-error (e)
                        (error 'jsonrpc-timeout
                               :message "JSON-RPC synchronous call has been timeout")))))
        (if (typep result 'error)
            (error result)
            result)))))

(defun notify-to (from to method &optional params)
  (check-type params jsonrpc-params)
  (send-message from
                to
                (make-request :method method
                              :params params)))

(defgeneric call (jsonrpc method &optional params &rest options)
  (:method ((client client) method &optional params &rest options)
    (ensure-connected client)
    (apply #'call-to client (transport-connection (jsonrpc-transport client))
           method params options)))

(defgeneric call-async (jsonrpc method &optional params callback error-callback)
  (:method ((client client) method &optional params callback error-callback)
    (ensure-connected client)
    (call-async-to client (transport-connection (jsonrpc-transport client))
                   method params
                   callback
                   error-callback))
  (:method ((server server) method &optional params callback error-callback)
    (unless (boundp '*connection*)
      (error 'jsonrpc-error :message "`call' is called outside of handlers."))
    (call-async-to server *connection* method params callback error-callback)))

(defgeneric notify (jsonrpc method &optional params)
  (:method ((client client) method &optional params)
    (ensure-connected client)
    (notify-to client (transport-connection (jsonrpc-transport client))
               method params))
  (:method ((server server) method &optional params)
    (unless (boundp '*connection*)
      (error 'jsonrpc-error :message "`notify' is called outside of handlers."))
    (notify-to server *connection*
               method params)))

(defgeneric notify-async (jsonrpc method &optional params)
  (:method ((client client) method &optional params)
    (ensure-connected client)
    (let ((connection (transport-connection (jsonrpc-transport client))))
      (send-message client connection
                    (make-request :method method
                                  :params params))))
  (:method ((server server) method &optional params)
    (unless (boundp '*connection*)
      (error 'jsonrpc-error :message "`notify-async' is called outside of handlers."))
    (send-message server *connection*
                  (make-request :method method
                                :params params))))

;; Experimental
(defgeneric broadcast (jsonrpc method &optional params)
  (:method ((server server) method &optional params)
    (dolist (conn (server-client-connections server))
      (notify server conn method params))))

;; Experimental
(defgeneric multicall-async (jsonrpc method &optional params callback error-callback)
  (:method ((server server) method &optional params callback error-callback)
    (dolist (conn (server-client-connections server))
      (call-async-to server conn method params
                     callback
                     error-callback))))
