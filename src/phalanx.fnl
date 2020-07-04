(include :lib.globals)
(global col globals.col)
(global dir globals.dir)

(global lume (require :lib.lume))
(global machine (require :lib.fsm))
(global inspect (require :lib.inspect))



;; ----------------------------------------------
;; |           Immutable functions              |
;; |                                            |
;; ----------------------------------------------

(fn only [color board]
    "return the stones for the given color"
    (lume.filter board #(= (. $1 :color) color)))

(fn free-stones-count [color board]
    "the number of remain stones (max of 9) looking at the stone-map"
    (- 9 (lume.count (only color board))))

(fn stone-at [x y board]
    "returns  (values stone board-index)"
    (lume.match board (lambda [stone]
                        (and (= stone.x x)
                             (= stone.y y)))))

(fn color-at [x y board]
    "the color at the coords"
    (match (pick-values 1 (stone-at x y board))
           nil nil
           spot spot.color))

(fn other [color]
    "black to white and white to black"
    (match color
           col.WHITE col.BLACK
           col.BLACK col.WHITE
           _ nil))

(fn in-bounds [coord]
    (let [{: x : y} coord]
      (and (> x 0)
           (<= x globals.map-size)
           (> y 0)
           (<= y globals.map-size)
           (not (and (= x 1) (= y 1)))    ;; exclude black temple
           (not (and (= x 9) (= y 9)))))) ;; exclude white temple

(fn find-neighbors [x y color board]
    "return the orthogonal neighbors which are the desired color. passing nil for color will find open neighbors"
    (let [neighbors [{ :x (+ x 1) :y y}
                     { :x (- x 1) :y y}
                     { :x x :y (+ y 1)}
                     { :x x :y (- y 1)}]]
      (lume.filter neighbors
                   (lambda [neighbor]
                     (and (= color (color-at neighbor.x neighbor.y board))
                          (in-bounds neighbor))))))

(fn possible-adds [?color board]
    "possible locations for the add action for a color on a map.
     [{event:'add' x:2 y:3}]"
    (local moves [])
    (lume.each
     (if ?color (only ?color board) board)
     (lambda [stone]
       (lume.each (find-neighbors stone.x stone.y nil board)
                  #(table.insert moves (lume.merge $1 {:event "add"})))))
    (lume.unique moves))

(fn remove-stone [x y old-board]
    "return a new board with a stone removed at given coords"
    (lume.reject old-board (lambda [spot]
                             (and (= x spot.x)
                                  (= y spot.y)))))

(fn place-stone [x y color old-board]
    "return a new board with a stone added given coords"
    (let [new-board (lume.deepclone old-board)]
      (table.insert new-board {: x : y : color})
      (lume.unique new-board)))

(fn possible-moves [color board]
    "possible moves for the board, a move consists of 2 from->to locations
     [{event:'move' moves: [{x:1 y:1 x2:2 y2:3}, {x:1 y:1 x2:2 y2:3}]}]"
    (fn possible-moves-tail [color board]
        (lume.each (only color board)
               (lambda [from]
                 (let [board (remove-stone from.x from.y board)]
                   (-> board
                       (possible-adds color)
                       (lume.map
                        (lambda [to]
                          {:x from.x
                           :y from.y
                           :x2 to.x
                           :y2 to.y})))))))
    (var moves {})
    (lume.each (possible-moves-tail color board)
               (lambda [move1]
                 (let [second-move-board (-?> (remove-stone move1.x move1.y color board)
                                              (place-stone move1.x2 move1.y2 color))]
                   (lume.each (possible-moves-tail color second-move-board)
                              (lambda [move2]
                                (table.insert moves {:event "move"
                                                     :moves {move1 move2}}))))))
    moves)

(fn opposite [direction]
    (match direction
           dir.LEFT dir.RIGHT
           dir.RIGHT dir.LEFT
           dir.UP dir.DOWN
           dir.DOWN dir.UP))

(fn direction-iters [direction]
    (match direction
           dir.LEFT (values #(- $1 1) #$1)
           dir.RIGHT (values #(+ $1 1) #$1)
           dir.UP (values #$1 #(- $1 1))
           dir.DOWN (values #$1 #(+ $1 1))))


(fn get-starting-position [x y color direction board]
    (let [opponate-color (other color)
                         (x-iter y-iter) (direction-iters (opposite direction))] ;; NOTE: we need to look backwords
      (fn get-starting-position-tail [x y]
          (match (color-at (x-iter x) (y-iter y) board)
                 nil (values x y)
                 opponate-color (values x y)
                 color (get-starting-position-tail (x-iter x) (y-iter y))))
      (get-starting-position-tail x y)))

(fn is-possible-push [start-x start-y color direction board]
    "check if pushing a line starting from a point for a color in a direction is valid"
    (let [(start-x start-y) (get-starting-position start-x start-y color direction board)
          (x-iter y-iter) (direction-iters direction)
          opponate-color (other color)]
      (fn is-possible-push-tail [x y ally-count opponate-count]
          (match (color-at x y board)
                 color (if (> opponate-count 0)
                           false ;; you've blocked yourself
                           (is-possible-push-tail (x-iter x) (y-iter y) (+ 1 ally-count) opponate-count))
                 opponate-color (is-possible-push-tail (x-iter x) (y-iter y) ally-count (+ 1 opponate-count))
                 nil (and (> opponate-count 0) ;; must actually touch opponate
                          (>  ally-count opponate-count))))  ;; must be longer then opponate
      (if (= color (color-at start-x start-y board))
          (is-possible-push-tail start-x start-y 0 0)
          false))) ;; must start on your own color

(fn possible-pushes [color board]
    "list of all possible pushes for a color on the board
    [{event:'push' x:1 y:2 direction:'UP'}]"
    (let [board (only color board)
          pushes {}]
      (lume.each board
                 (lambda [stone]
                   (lume.each [dir.LEFT dir.RIGHT dir.UP dir.DOWN]
                              (lambda [direction]
                                (when (is-possible-push stone.x stone.y color direction board)
                                  (table.insert pushes (lume.extend stone {:direction direction :event "push"})))))))
      (lume.unique pushes)))

(fn is-possible-add [x y color board]
    "check if the x y coords and a color is a valid add move"
    (lume.any (possible-adds color board)
              (lambda [stone]
                (and (= stone.x x) (= stone.y y)))))

(fn army-at [x y color board]
    "find all connected pieces (an army) for a color starting at a position"
    (fn army-tail [x y seen-stones]
        (lume.each (find-neighbors x y color board)
                   (lambda [stone]
                     (when (not (stone-at stone.x stone.y seen-stones))
                       (table.insert seen-stones {:x stone.x :y stone.y :color color})
                       (lume.concat seen-stones (army-tail stone.x stone.y seen-stones)))))
        seen-stones)
    (army-tail x y []))


(fn dead-stones [board]
    "list of all the dead/isolated stones on the board"
    (lume.filter board (lambda [stone]
                         (or (= 0 (# (find-neighbors stone.x stone.y stone.color board)))
                             (not (in-bounds stone))))))

(fn place-stones [stones old-board]
    (let [new-board (lume.deepclone old-board)]
      (lume.each stones #(table.insert new-board $1))
      (lume.unique new-board)))

(fn remove-stones [stones old-board]
    "return a new board with all the stones given removed"
    (lume.unique (lume.reject old-board
                              (lambda [spot]
                                (lume.any stones (lambda [dspot]
                                                   (and (= dspot.x spot.x)
                                                        (= dspot.y spot.y))))))))

(fn push [x y color direction old-board]
    "return a new board after a push action at the given coords and direction"
    (let [new-board (lume.deepclone old-board)
                    (start-x start-y) (get-starting-position x y color direction new-board)
                    (x-iter y-iter) (direction-iters direction)]
      (fn push-line-tail [x y board]
          (match (stone-at x y old-board)
                 (next-stone index) (do
                                     (tset new-board index {:x (x-iter x) :y (y-iter y) :color next-stone.color})
                                     (when (~= nil next-stone.color)
                                       (push-line-tail (x-iter x) (y-iter y) next-stone.color)))))
      (push-line-tail start-x start-y)
      (lume.unique new-board)))

(fn undo-push [x y color direction old-board]
    "return a new board after a push action at the given coords and direction has been undone. This requires some special attention/tweaks"
    (let [new-board (lume.deepclone old-board)
                    (x-iter y-iter) (direction-iters direction)
                    (start-x start-y) (get-starting-position (x-iter x) (y-iter y) color direction new-board)
                    (opp-x-iter opp-y-iter) (direction-iters (opposite direction))]
      (fn pushnt-line-tail [x y board]
          (match (stone-at x y old-board)
                 (next-stone index) (do
                                     (tset new-board index {:x (opp-x-iter x) :y (opp-y-iter y) :color next-stone.color})
                                     (when (~= nil next-stone.color)
                                       (pushnt-line-tail (x-iter x) (y-iter y) next-stone.color)))))
      (pushnt-line-tail start-x start-y)
      (lume.unique new-board)))


(fn neighbor-of [x y x-goal y-goal]
    "check if (x,y) is a neighbor of (x-goal, y-goal)"
    (let [neighbors [{ :x (+ x 1) :y y}
                     { :x (- x 1) :y y}
                     { :x x :y (+ y 1)}
                     { :x x :y (- y 1)}]]
      (lume.any neighbors (lambda [spot]
                            (and (= spot.x x-goal)
                                 (= spot.y y-goal))))))

(fn goal-position [color]
    (values (if (= color col.BLACK) 1 9)
            (if (= color col.BLACK) 1 9)))

(fn touching-temple [color board]
    "check if color is touching the temple"
    (let [(x-goal y-goal) (goal-position color)]
      (lume.any board (lambda [spot]
                        (and (= spot.color color)
                             (neighbor-of spot.x spot.y x-goal y-goal))))))

(fn game-over [board]
    "return color that has won the game, else false"
    (if
     ;; Win by evisceration
     (= 9 (free-stones-count col.BLACK board)) col.WHITE
     (= 9 (free-stones-count col.WHITE board)) col.BLACK
     ;; Win by touching the temple
     (touching-temple col.BLACK board) col.BLACK
     (touching-temple col.WHITE board) col.WHITE
     ;; game is STILL ON
     false))

;; ------------------------------------------------------|
;; |       Finite State Machine & Global State           |
;; |      Imparative code below, enter with causion      |
;; |                                                     |
;; ------------------------------------------------------|

(fn take-an-action [self]
    (tset self.state :current-turn-action-counter (- self.state.current-turn-action-counter 1)))

(fn give-an-action [self]
    (tset self.state :current-turn-action-counter (+ self.state.current-turn-action-counter 1)))

(fn onenter-selecting-action [self]
    (tset self.state :army nil)
    (let [dead-stones (dead-stones self.state.board)]
      (when (> (# dead-stones) 0) (self:clean dead-stones)))
    (when (= self.state.current-turn-action-counter 0)
      (tset self.state :current-turn (other self.state.current-turn))
      (tset self.state :current-turn-action-counter 2)
      (self:clearHistory))
    ;; TODO: this is broken
    ;; (let [winner (game-over self.state.board)]
    ;;   (when winner (self.endgame winner)))
    )

(fn onbefore-clean [self _event _from _to dead-stones]
    "an intermediate transition to put the removed stones into the history stack"
    (tset self.state :board (remove-stones dead-stones self.state.board)))

(fn onundo-clean [self _event _from _to reborn-stones]
    "an intermediate transition to revive dead stones from the history stack, undoes the next transition as well"
    (tset self.state :board (place-stones reborn-stones self.state.board))
    (self:undoTransition))

(fn onbefore-add [self]
    (if (> (free-stones-count self.state.current-turn self.state.board) 0)
        (take-an-action self)
        false))

(fn onundo-add [self]
    (give-an-action self))

(fn onbefore-move [self _event from]
    (when (= from :selecting-action) (take-an-action self)))

(fn onundo-move [self]
    (give-an-action self))

(fn onbefore-pick [self _event _from _to x y]
    (if (= (color-at x y self.state.board) self.state.current-turn)
        (tset self.state :board (remove-stone x y self.state.board))
        false))

(fn onundo-pick [self _event _from _to x y]
    (tset self.state :board (place-stone x y self.state.current-turn self.state.board)))

(fn onenter-placing-stone [self _event _from _to x y]
    (when (= (type x) "number")
      (self:setarmy (army-at x y self.state.current-turn self.state.board))))

(fn onbefore-place [self _event _from _to x y]
    (let [board (or self.state.army self.state.board)]
      (if (is-possible-add x y self.state.current-turn board)
          (tset self.state :board (place-stone x y self.state.current-turn self.state.board))
          false)))

(fn onbefore-setarmy [self _event _from _to army]
    (tset self.state :army army))

(fn onundo-setarmy [self _event _from _to army]
    "an intermediate transition to revive past army state from the history stack, undoes the next transition as well"
    (tset self.state :army army)
    (self:undoTransition))

(fn onundo-place [self _event _from _to x y]
    (tset self.state :board (remove-stone x y self.state.board)))

(fn onbefore-lineup [self] (take-an-action self))
(fn onundo-lineup [self] (give-an-action self))

(fn onbefore-push [self _event _from _to x y direction]
    (if (is-possible-push x y self.state.current-turn direction self.state.board)
        (tset self.state :board (push x y self.state.current-turn direction self.state.board))
        false))

(fn onundo-push [self _even _from _to x y direction]
    (tset self.state :board (undo-push x y self.state.current-turn direction self.state.board)))

(fn onenter-game-over [self event from to winner]
    (print winner))

(fn init-board [?board ?turn]
    (machine.create {:state {:army nil ;; used for limiting move actions
                             :current-turn-action-counter 2
                             :current-turn (or ?turn col.BLACK)
                             :board (or ?board
                                        [{:x 2 :y 2 :color col.WHITE}
                                         {:x 2 :y 3 :color col.WHITE}
                                         {:x 3 :y 2 :color col.WHITE}
                                         {:x 3 :y 3 :color col.WHITE}
                                         {:x 7 :y 7 :color col.BLACK}
                                         {:x 7 :y 8 :color col.BLACK}
                                         {:x 8 :y 7 :color col.BLACK}
                                         {:x 8 :y 8 :color col.BLACK}])}
                     :initial "selecting-action"
                     :events [;; Move
                              {:name "move" :from "selecting-action" :to "picking-first-stone"}
                              {:name "pick" :from "picking-first-stone" :to "placing-first-stone"}
                              {:name "place" :from "placing-first-stone" :to "picking-second-stone"}
                              {:name "pick" :from "picking-second-stone" :to "placing-second-stone"}
                              ;; Add
                              {:name "add" :from "selecting-action" :to "placing-stone"}
                              ;; Add / Move
                              {:name "place" :from ["placing-stone" "placing-second-stone"] :to "selecting-action"}
                              ;; Push
                              {:name "lineup" :from "selecting-action" :to "picking-push-line"}
                              {:name "push" :from "picking-push-line" :to "selecting-action"}
                              ;; Gameover
                              {:name "endgame" :from "selecting-action" :to "game-over"}
                              ;; remove dead stones (is an action so they are stored in history)
                              {:name "clean" :from "selecting-action" :to "selecting-action"}
                              ;; store army changes in history
                              {:name "setarmy" :from "placing-first-stone" :to "placing-first-stone"}
                              {:name "setarmy" :from "placing-second-stone" :to "placing-second-stone"}]
                     :callbacks {: onenter-selecting-action
                                 : onbefore-clean   : onundo-clean
                                 : onbefore-add     : onundo-add
                                 : onbefore-move    : onundo-move
                                 : onbefore-pick    : onundo-pick
                                 : onbefore-place   : onundo-place
                                 : onbefore-lineup  : onundo-lineup
                                 : onbefore-push    : onundo-push
                                 : onbefore-setarmy : onundo-setarmy
                                 :onenter-placing-first-stone onenter-placing-stone
                                 :onenter-placing-second-stone onenter-placing-stone
                                 : onenter-game-over}}))

{: init-board}
