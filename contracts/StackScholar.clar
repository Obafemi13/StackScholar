(define-constant max-milestones u5)
(define-constant nft-id-base u1000)

(define-data-var next-scholarship-id uint u1)
(define-data-var next-nft-id uint nft-id-base)

;; NFT to represent student scholarship
(define-non-fungible-token scholarship-nft uint)

;; Scholarships data
(define-map scholarships
  uint
  {
    donor: principal,
    student: (optional principal),
    total-fund: uint,
    milestones: uint, ;; number of total milestones
    milestone-value: uint, ;; payout per milestone
    bonus: uint,
    claimed: uint, ;; number of completed milestones
    active: bool
  }
)

;; Record of milestone completions
(define-map milestone-status
  { scholarship-id: uint, student: principal, milestone: uint }
  bool
)

;; ---------------------------------------------
;; Function: create-scholarship
;; Donor funds a scholarship and defines terms
;; ---------------------------------------------
(define-public (create-scholarship (milestones uint) (milestone-value uint) (bonus uint))
  (begin
    (asserts! (<= milestones max-milestones) (err u100)) ;; exceeds max milestones
    (let (
      (sch-id (var-get next-scholarship-id))
      (total (* milestone-value milestones))
      (required (+ total bonus))
    )
      (asserts! (>= (stx-get-balance tx-sender) required) (err u101)) ;; insufficient balance
      (try! (stx-transfer? required tx-sender (as-contract tx-sender))) ;; send funds to contract

      (map-set scholarships sch-id {
        donor: tx-sender,
        student: none,
        total-fund: required,
        milestones: milestones,
        milestone-value: milestone-value,
        bonus: bonus,
        claimed: u0,
        active: true
      })

      (var-set next-scholarship-id (+ sch-id u1))
      (ok sch-id)
    )
  )
)

;; ---------------------------------------------
;; Function: assign-scholarship
;; Donor assigns a student and mints NFT
;; ---------------------------------------------
(define-public (assign-scholarship (sch-id uint) (student principal))
  (begin
    (let ((sch (map-get? scholarships sch-id)))
      (match sch
        s
          (begin
            (asserts! (is-eq (get donor s) tx-sender) (err u102)) ;; only donor can assign
            (asserts! (is-none (get student s)) (err u103)) ;; already assigned

            ;; Update map
            (map-set scholarships sch-id (merge s { student: (some student) }))

            ;; Mint NFT
            (let ((nft-id (var-get next-nft-id)))
              (try! (nft-mint? scholarship-nft nft-id student))
              (var-set next-nft-id (+ nft-id u1))
              (ok nft-id)
            )
          )
        (err u104) ;; invalid scholarship ID
      )
    )
  )
)

;; ---------------------------------------------
;; Function: verify-milestone
;; Donor or oracle confirms a milestone is complete
;; ---------------------------------------------
(define-public (verify-milestone (sch-id uint) (milestone-id uint))
  (let ((sch (map-get? scholarships sch-id)))
    (match sch
      s
        (begin
          (asserts! (get active s) (err u105)) ;; inactive scholarship
          (asserts! (is-some (get student s)) (err u106)) ;; no student
          (asserts! (<= milestone-id (get milestones s)) (err u107)) ;; invalid milestone
          (asserts! (not (default-to false (map-get? milestone-status {
            scholarship-id: sch-id, student: (unwrap! (get student s) (err u108)), milestone: milestone-id
          }))) (err u109)) ;; already verified

          ;; mark milestone
          (map-set milestone-status {
            scholarship-id: sch-id,
            student: (unwrap! (get student s) (err u108)),
            milestone: milestone-id
          } true)

          ;; update claimed count
          (map-set scholarships sch-id (merge s { claimed: (+ (get claimed s) u1) }))

          ;; pay student
          (try! (stx-transfer? (get milestone-value s) (as-contract tx-sender) (unwrap! (get student s) (err u108))))

          (ok true)
        )
      (err u104)
    )
  )
)

;; ---------------------------------------------
;; Function: claim-bonus
;; Student claims final bonus if all milestones complete
;; ---------------------------------------------
(define-public (claim-bonus (sch-id uint))
  (let ((sch (map-get? scholarships sch-id)))
    (match sch
      s
        (let ((student-principal (unwrap! (get student s) (err u108))))
          (asserts! (is-eq tx-sender student-principal) (err u110))
          (asserts! (get active s) (err u105))
          (asserts! (is-eq (get claimed s) (get milestones s)) (err u111)) ;; not yet complete

          ;; mark inactive
          (map-set scholarships sch-id (merge s { active: false }))

          ;; transfer bonus
          (try! (stx-transfer? (get bonus s) (as-contract tx-sender) student-principal))
          (ok true)
        )
      (err u104)
    )
  )
)

;; ---------------------------------------------
;; Function: revoke-scholarship
;; Donor revokes if milestones not complete
;; ---------------------------------------------
(define-public (revoke-scholarship (sch-id uint))
  (let ((sch (map-get? scholarships sch-id)))
    (match sch
      s
        (begin
          (asserts! (is-eq (get donor s) tx-sender) (err u102))
          (asserts! (get active s) (err u105))

          ;; calculate unclaimed funds
          (let (
            (total-paid (* (get milestone-value s) (get claimed s)))
            (unclaimed (- (get total-fund s) total-paid))
          )
            (map-set scholarships sch-id (merge s { active: false }))
            (try! (stx-transfer? unclaimed (as-contract tx-sender) (get donor s)))
            (ok true)
          )
        )
      (err u104)
    )
  )
)

;; ---------------------------------------------
;; Read-Only: get-scholarship-status
;; ---------------------------------------------
(define-read-only (get-scholarship-status (sch-id uint))
  (match (map-get? scholarships sch-id)
    s (ok {
      donor: (get donor s),
      student: (get student s),
      milestones: (get milestones s),
      claimed: (get claimed s),
      active: (get active s)
    })
    (err u104)
  )
)
