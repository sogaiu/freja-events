# a push-pull system
# events are pushed to queues
# then things can pull from the queues

# functions to not block the fiber when interacting with channels
(defn pop
  ``
  Like `ev/take` but non-blocking, instead returns `nil` if the
  channel is empty.
  ``
  [chan]
  (when (pos? (ev/count chan))
    (ev/take chan)))

(comment

  (let [c (ev/chan 1)]
    (ev/give c :hello)
    (pop c))
  # =>
  :hello

  (let [c (ev/chan 1)]
    (pop c))
  # =>
  nil

  )

(defn push!
  ``
  Like `ev/give`, but if the channel is full, throw away the
  oldest value.
  ``
  [chan v]
  (when (ev/full chan)
    (ev/take chan)) ## throw away old values
  (ev/give chan v))

(comment

  (let [c (ev/chan 1)]
    (ev/give c :hello)
    (push! c :smile)
    (pop c))
  # =>
  :smile

  (let [c (ev/chan 1)]
    (push! c :smile)
    (pop c))
  # =>
  :smile

  )

(defn vs
  ``
  Returns the values in a channel.
  ``
  [chan]
  (def vs @[])
  # empty the queue
  (loop [v :iterate (pop chan)]
    (array/push vs v))
  # then put them back again
  (loop [v :in vs]
    (push! chan v))
  #
  vs)

(comment

  (let [c (ev/chan 2)]
    (push! c :hi)
    (push! c :there)
    (push! c :or-not)
    (vs c))
  # =>
  @[:there :or-not]

  )

# we want to be able to pull
# multiple things should be able to pull from it
# essentially splitting the value

(defn pull
  [pullable pullers]
  (when-let [v (case (type pullable)
                 :core/channel
                 (pop pullable)
                 #
                 :table
                 (when (pullable :event/changed)
                   (put pullable :event/changed false))
                 #
                 (error (string (type pullable) " is not a pullable.")))]
    (loop [puller :in pullers]
      (try
        (case (type puller)
          :function
          (puller v)
          #
          :core/channel
          (push! puller v)
          #
          :table
          (:on-event puller v)
          #
          (errorf "Pulling not implemented for %p" (type puller)))
        ([err fib]
          # XXX: in freja, the err is push!-ed to state/eval-results
          #      make pluggable via dynamic variable?
          (pp (if (and (dictionary? err) (err :error))
                err
                (let [event
                      (if (dictionary? v)
                        (string/format "dictionary with keys: %p"
                                       (keys v))
                        v)
                      subscriber
                      (if (dictionary? puller)
                        (string/format "dictionary with keys: %p"
                                       (keys puller))
                        puller)]
                  {:error err
                   :fiber fib
                   :msg (string/format
                          ``
                             %s
                             event:
                             %p
                             subscriber:
                             %p
                             ``
                          err event subscriber)
                   :cause [v puller]}))))))
    # if there was a value, we return it
    v))

(comment

  (def a-number
    (math/rng-int (math/rng (os/cryptorand 2))
                  21))
  (let [res @[]
        #
        pullable (ev/chan 1)
        _ (ev/give pullable a-number)
        #
        puller-1 (fn [v]
                   (array/push res (inc v)))
        puller-2 @{:on-event (fn [tbl v]
                               (array/push res (dec v)))}
        #
        _ (pull pullable [puller-1 puller-2])]
    res)
  # =>
  @[(inc a-number) (dec a-number)]

  )

(defn pull-all
  [pullable pullers]
  (while (pull pullable pullers)
    nil))

(comment

  (def a-number
    (math/rng-int (math/rng (os/cryptorand 2))
                  21))
  (def other-number
    (math/rng-int (math/rng (os/cryptorand 2))
                  11))
  (let [res @[]
        #
        pullable (ev/chan 2)
        _ (ev/give pullable a-number)
        _ (ev/give pullable other-number)
        #
        puller-1 (fn [v]
                   (array/push res (inc v)))
        puller-2 @{:on-event (fn [tbl v]
                               (array/push res (dec v)))}
        #
        _ (pull-all pullable [puller-1 puller-2])]
    res)
  # =>
  @[(inc a-number) (dec a-number)
    (inc other-number) (dec other-number)]

  )

(defn put!
  [state k v]
  (-> state
      (put k v)
      (put :event/changed true)))

(comment

  (let [state @{:a 1}]
    (put! state :b 2))
  # =>
  @{:a 1
    :b 2
    :event/changed true}

  )

(defn update!
  [state k f & args]
  (-> state
      (update k f ;args)
      (put :event/changed true)))

(comment

  (let [state @{:a 1}]
    (update! state :a inc))
  # =>
  @{:a 2
    :event/changed true}

  )

# XXX: not used outside of testing yet
# (defn record-all
#   [pullables]
#   (loop [[pullable pullers] :pairs pullables]
#     (case (type pullable)
#       :core/channel
#       (array/push pullers
#                   @{:history (ev/chan 10000)
#                     :on-event (fn [self ev]
#                                 (update self :history push! ev))})
#       #
#       :table
#       (array/push pullers
#                   @{:history (freeze pullable)
#                     :on-event (fn [self ev] nil)})))
#   pullables)

(defn fresh?
  [pullable]
  (case (type pullable)
    :core/channel
    (pos? (ev/count pullable))
    #
    :table
    (pullable :event/changed)))

(comment

  (fresh? @{:a 1})
  # =>
  nil

  (fresh? (put! @{:a 1} :b 2))
  # =>
  true

  (let [c (ev/chan 1)]
    (fresh? c))
  # =>
  false

  (let [c (ev/chan 1)]
    (ev/give c :smile)
    (fresh? c))
  # =>
  true

  )

(varfn pull-deps
  [deps &opt finally]
  # as long as dependencies have changed (are `fresh?`)
  # keep looping through them and tell dependees
  # that changes have happened (`pull-all`)
  (while (some fresh? (keys deps))
    (loop [[pullable pullers] :pairs deps]
      (pull-all pullable pullers)))
  # then when all is done, run the things in `finally`
  (loop [[pullable pullers] :pairs (or finally {})]
    (pull-all pullable pullers)))

(comment

  (let [res @[]
        a-number
        (math/rng-int (math/rng (os/cryptorand 2))
                      21)
        #
        pullable-1 (ev/chan 2)
        _ (ev/give pullable-1 a-number)
        pullable-2 @{:a 1
                     :event/changed true}
        #
        puller-1 (fn [v]
                   (array/push res (inc v)))
        puller-2 @{:on-event (fn [tbl v]
                               (array/push res (v :event/changed)))}]
    (pull-deps @{pullable-1 @[puller-1]
                 pullable-2 @[puller-2]})
    #
    (or (deep= res
               @[(inc a-number) false])
        (deep= res
               @[false (inc a-number)])))
  # =>
  true

  )
