;; Decentralized Retirement Fund Smart Contract
;; A blockchain-based retirement savings system with employer matching,
;; vesting schedules, early withdrawal penalties, and investment pools

;; ===================================
;; CONSTANTS
;; ===================================

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-RETIREMENT-AGE u65)
(define-constant EARLY-WITHDRAWAL-PENALTY-RATE u10) ;; 10%
(define-constant MAX-CONTRIBUTION-RATE u50) ;; 50% of salary
(define-constant MIN-VESTING-PERIOD u365) ;; 1 year in days
(define-constant MAX-VESTING-PERIOD u1825) ;; 5 years in days
(define-constant COMPOUND-FREQUENCY u365) ;; Daily compounding

;; Investment pool types
(define-constant CONSERVATIVE-POOL u1)
(define-constant BALANCED-POOL u2)
(define-constant AGGRESSIVE-POOL u3)

;; Account status
(define-constant ACCOUNT-ACTIVE u1)
(define-constant ACCOUNT-SUSPENDED u2)
(define-constant ACCOUNT-RETIRED u3)

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ACCOUNT-NOT-FOUND (err u101))
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-ACCOUNT-SUSPENDED (err u104))
(define-constant ERR-NOT-RETIREMENT-AGE (err u105))
(define-constant ERR-EMPLOYER-NOT-FOUND (err u106))
(define-constant ERR-VESTING-NOT-COMPLETE (err u107))
(define-constant ERR-INVALID-POOL-TYPE (err u108))
(define-constant ERR-CONTRIBUTION-LIMIT-EXCEEDED (err u109))
(define-constant ERR-INVALID-PARAMETERS (err u110))

;; ===================================
;; DATA VARIABLES
;; ===================================

;; Global fund statistics
(define-data-var total-assets uint u0)
(define-data-var total-participants uint u0)
(define-data-var fund-inception-block uint u0)

;; Investment pool returns (annual percentage scaled by 10000)
(define-data-var conservative-pool-return uint u400) ;; 4%
(define-data-var balanced-pool-return uint u700) ;; 7%
(define-data-var aggressive-pool-return uint u1000) ;; 10%

;; ===================================
;; DATA MAPS
;; ===================================

;; Participant retirement accounts
(define-map retirement-accounts
  { participant: principal }
  {
    employee-balance: uint,
    employer-balance: uint,
    total-contributions: uint,
    total-employer-match: uint,
    investment-pool: uint,
    account-status: uint,
    creation-block: uint,
    birth-year: uint,
    annual-salary: uint,
    contribution-rate: uint,
    last-contribution-block: uint,
    vesting-start-block: uint,
    vesting-period-days: uint
  }
)

;; Employer information and matching policies
(define-map employers
  { employer: principal }
  {
    company-name: (string-ascii 100),
    match-rate: uint, ;; Percentage of employee contribution matched
    max-match-amount: uint, ;; Maximum annual match amount
    vesting-schedule: uint, ;; Vesting period in days
    total-employees: uint,
    total-contributions: uint,
    is-active: bool,
    registration-block: uint
  }
)

;; Employee-Employer relationships
(define-map employee-employer
  { employee: principal }
  { employer: principal, start-date: uint, is-active: bool }
)

;; Withdrawal history
(define-map withdrawal-history
  { participant: principal, withdrawal-id: uint }
  {
    amount: uint,
    withdrawal-type: uint, ;; 1=regular, 2=early, 3=hardship
    penalty-amount: uint,
    withdrawal-block: uint,
    reason: (string-ascii 200)
  }
)

;; Investment pool balances
(define-map investment-pools
  { pool-type: uint }
  {
    total-balance: uint,
    participant-count: uint,
    annual-return: uint,
    last-update-block: uint
  }
)

;; Contribution limits by year
(define-map annual-contribution-limits
  { year: uint }
  { employee-limit: uint, catch-up-limit: uint }
)

;; ===================================
;; PRIVATE FUNCTIONS
;; ===================================

;; Helper function to get minimum of two values
(define-private (min-uint (a uint) (b uint))
  (if (<= a b) a b)
)

;; Calculate age based on birth year and current block
(define-private (calculate-age (birth-year uint))
  (let ((current-year (+ u2024 (/ (- stacks-block-height u1000000) u52560)))) ;; Approximate blocks per year
    (- current-year birth-year)
  )
)

;; Calculate vested amount based on vesting schedule
(define-private (calculate-vested-amount 
  (employer-balance uint) 
  (vesting-start-block uint) 
  (vesting-period-days uint)
)
  (let (
    (blocks-since-vesting-start (- stacks-block-height vesting-start-block))
    (blocks-per-day u144) ;; Approximate blocks per day
    (days-vested (/ blocks-since-vesting-start blocks-per-day))
    (vesting-percentage (if (>= days-vested vesting-period-days)
                          u10000 ;; 100% vested
                          (/ (* days-vested u10000) vesting-period-days)))
  )
    (/ (* employer-balance vesting-percentage) u10000)
  )
)

;; Calculate early withdrawal penalty
(define-private (calculate-early-withdrawal-penalty (amount uint))
  (/ (* amount EARLY-WITHDRAWAL-PENALTY-RATE) u100)
)

;; Calculate compound interest for investment pools
(define-private (calculate-compound-interest 
  (principal uint) 
  (annual-rate uint) 
  (blocks-elapsed uint)
)
  (let (
    (blocks-per-year u52560) ;; Approximate blocks per year
    (years-elapsed (/ blocks-elapsed blocks-per-year))
    (rate-decimal (/ annual-rate u10000))
  )
    ;; Simple compound interest calculation
    (- (pow (+ u10000 annual-rate) years-elapsed) u10000)
  )
)

;; Validate investment pool type
(define-private (is-valid-pool-type (pool-type uint))
  (or (is-eq pool-type CONSERVATIVE-POOL)
      (is-eq pool-type BALANCED-POOL)
      (is-eq pool-type AGGRESSIVE-POOL))
)

;; Get investment pool return rate
(define-private (get-pool-return-rate (pool-type uint))
  (if (is-eq pool-type CONSERVATIVE-POOL)
    (var-get conservative-pool-return)
    (if (is-eq pool-type BALANCED-POOL)
      (var-get balanced-pool-return)
      (var-get aggressive-pool-return)))
)

;; ===================================
;; PUBLIC FUNCTIONS - ACCOUNT MANAGEMENT
;; ===================================

;; Create a new retirement account
(define-public (create-retirement-account 
  (birth-year uint) 
  (annual-salary uint) 
  (contribution-rate uint)
  (investment-pool uint)
)
  (let (
    (participant tx-sender)
    (existing-account (map-get? retirement-accounts { participant: participant }))
  )
    (asserts! (is-none existing-account) ERR-ACCOUNT-NOT-FOUND)
    (asserts! (<= contribution-rate MAX-CONTRIBUTION-RATE) ERR-CONTRIBUTION-LIMIT-EXCEEDED)
    (asserts! (is-valid-pool-type investment-pool) ERR-INVALID-POOL-TYPE)
    (asserts! (> annual-salary u0) ERR-INVALID-PARAMETERS)
    (asserts! (>= birth-year u1940) ERR-INVALID-PARAMETERS)
    (asserts! (<= birth-year u2010) ERR-INVALID-PARAMETERS)
    
    ;; Create the retirement account
    (map-set retirement-accounts
      { participant: participant }
      {
        employee-balance: u0,
        employer-balance: u0,
        total-contributions: u0,
        total-employer-match: u0,
        investment-pool: investment-pool,
        account-status: ACCOUNT-ACTIVE,
        creation-block: stacks-block-height,
        birth-year: birth-year,
        annual-salary: annual-salary,
        contribution-rate: contribution-rate,
        last-contribution-block: u0,
        vesting-start-block: stacks-block-height,
        vesting-period-days: MIN-VESTING-PERIOD
      }
    )
    
    ;; Update global statistics
    (var-set total-participants (+ (var-get total-participants) u1))
    (ok true)
  )
)

;; Update account investment pool allocation
(define-public (update-investment-pool (new-pool-type uint))
  (let (
    (participant tx-sender)
    (account (unwrap! (map-get? retirement-accounts { participant: participant }) ERR-ACCOUNT-NOT-FOUND))
  )
    (asserts! (is-valid-pool-type new-pool-type) ERR-INVALID-POOL-TYPE)
    (asserts! (is-eq (get account-status account) ACCOUNT-ACTIVE) ERR-ACCOUNT-SUSPENDED)
    
    (map-set retirement-accounts
      { participant: participant }
      (merge account { investment-pool: new-pool-type })
    )
    (ok true)
  )
)

;; ===================================
;; PUBLIC FUNCTIONS - CONTRIBUTIONS
;; ===================================

;; Make employee contribution
(define-public (make-employee-contribution (amount uint))
  (let (
    (participant tx-sender)
    (account (unwrap! (map-get? retirement-accounts { participant: participant }) ERR-ACCOUNT-NOT-FOUND))
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (is-eq (get account-status account) ACCOUNT-ACTIVE) ERR-ACCOUNT-SUSPENDED)
    
    ;; Transfer STX from participant to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update account balances
    (map-set retirement-accounts
      { participant: participant }
      (merge account {
        employee-balance: (+ (get employee-balance account) amount),
        total-contributions: (+ (get total-contributions account) amount),
        last-contribution-block: stacks-block-height
      })
    )
    
    ;; Update global assets
    (var-set total-assets (+ (var-get total-assets) amount))
    
    ;; Trigger employer matching if applicable
    (match (get-employer-info participant)
      employer-info (begin
        (try! (process-employer-match participant amount employer-info))
        (ok amount)
      )
      (ok amount) ;; No employer, return the contribution amount
    )
  )
)

;; Process employer matching contribution
(define-private (process-employer-match 
  (employee principal) 
  (employee-contribution uint)
  (employer-info { employer: principal, start-date: uint, is-active: bool })
)
  (let (
    (employer (get employer employer-info))
    (employer-data (unwrap! (map-get? employers { employer: employer }) ERR-EMPLOYER-NOT-FOUND))
    (account (unwrap! (map-get? retirement-accounts { participant: employee }) ERR-ACCOUNT-NOT-FOUND))
    (match-rate (get match-rate employer-data))
    (max-match (get max-match-amount employer-data))
    (calculated-match (/ (* employee-contribution match-rate) u100))
    (match-amount (min-uint calculated-match max-match))
  )
    (if (> match-amount u0)
      (begin
        ;; Transfer match amount from employer to contract
        (try! (stx-transfer? match-amount employer (as-contract tx-sender)))
        
        ;; Update employee account with employer match
        (map-set retirement-accounts
          { participant: employee }
          (merge account {
            employer-balance: (+ (get employer-balance account) match-amount),
            total-employer-match: (+ (get total-employer-match account) match-amount)
          })
        )
        
        ;; Update employer statistics
        (map-set employers
          { employer: employer }
          (merge employer-data {
            total-contributions: (+ (get total-contributions employer-data) match-amount)
          })
        )
        
        ;; Update global assets
        (var-set total-assets (+ (var-get total-assets) match-amount))
        (ok match-amount)
      )
      (ok u0)
    )
  )
)

;; ===================================
;; PUBLIC FUNCTIONS - WITHDRAWALS
;; ===================================

;; Withdraw funds at retirement age
(define-public (withdraw-retirement-funds (amount uint))
  (let (
    (participant tx-sender)
    (account (unwrap! (map-get? retirement-accounts { participant: participant }) ERR-ACCOUNT-NOT-FOUND))
    (participant-age (calculate-age (get birth-year account)))
    (vested-employer-balance (calculate-vested-amount 
      (get employer-balance account)
      (get vesting-start-block account)
      (get vesting-period-days account)))
    (total-available (+ (get employee-balance account) vested-employer-balance))
  )
    (asserts! (>= participant-age MIN-RETIREMENT-AGE) ERR-NOT-RETIREMENT-AGE)
    (asserts! (<= amount total-available) ERR-INSUFFICIENT-BALANCE)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Transfer funds to participant
    (try! (as-contract (stx-transfer? amount tx-sender participant)))
    
    ;; Update account balances
    (if (<= amount (get employee-balance account))
      ;; Withdraw from employee balance first
      (map-set retirement-accounts
        { participant: participant }
        (merge account {
          employee-balance: (- (get employee-balance account) amount)
        })
      )
      ;; Withdraw from both employee and employer balances
      (let (
        (employee-portion (get employee-balance account))
        (employer-portion (- amount employee-portion))
      )
        (map-set retirement-accounts
          { participant: participant }
          (merge account {
            employee-balance: u0,
            employer-balance: (- (get employer-balance account) employer-portion)
          })
        )
      )
    )
    
    ;; Update global assets
    (var-set total-assets (- (var-get total-assets) amount))
    
    ;; Record withdrawal history
    (record-withdrawal participant amount u1 u0 "Regular retirement withdrawal")
    
    (ok amount)
  )
)

;; Early withdrawal with penalty
(define-public (withdraw-early (amount uint) (reason (string-ascii 200)))
  (let (
    (participant tx-sender)
    (account (unwrap! (map-get? retirement-accounts { participant: participant }) ERR-ACCOUNT-NOT-FOUND))
    (participant-age (calculate-age (get birth-year account)))
    (penalty-amount (calculate-early-withdrawal-penalty amount))
    (net-withdrawal (- amount penalty-amount))
    (available-balance (get employee-balance account)) ;; Only employee contributions for early withdrawal
  )
    (asserts! (< participant-age MIN-RETIREMENT-AGE) ERR-NOT-RETIREMENT-AGE)
    (asserts! (<= amount available-balance) ERR-INSUFFICIENT-BALANCE)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Transfer net amount to participant (after penalty)
    (try! (as-contract (stx-transfer? net-withdrawal tx-sender participant)))
    
    ;; Update account balance
    (map-set retirement-accounts
      { participant: participant }
      (merge account {
        employee-balance: (- (get employee-balance account) amount)
      })
    )
    
    ;; Update global assets (penalty stays in the fund)
    (var-set total-assets (- (var-get total-assets) net-withdrawal))
    
    ;; Record withdrawal history
    (record-withdrawal participant amount u2 penalty-amount reason)
    
    (ok net-withdrawal)
  )
)

;; Get next withdrawal ID for a participant
(define-private (get-next-withdrawal-id (participant principal))
  (let (
    (withdrawal-0 (map-get? withdrawal-history { participant: participant, withdrawal-id: u0 }))
    (withdrawal-1 (map-get? withdrawal-history { participant: participant, withdrawal-id: u1 }))
    (withdrawal-2 (map-get? withdrawal-history { participant: participant, withdrawal-id: u2 }))
  )
    (if (is-none withdrawal-0) u0
      (if (is-none withdrawal-1) u1
        (if (is-none withdrawal-2) u2 u3)))
  )
)

;; Record withdrawal in history
(define-private (record-withdrawal 
  (participant principal) 
  (amount uint) 
  (withdrawal-type uint) 
  (penalty uint) 
  (reason (string-ascii 200))
)
  (let (
    (withdrawal-id (get-next-withdrawal-id participant))
  )
    (map-set withdrawal-history
      { participant: participant, withdrawal-id: withdrawal-id }
      {
        amount: amount,
        withdrawal-type: withdrawal-type,
        penalty-amount: penalty,
        withdrawal-block: stacks-block-height,
        reason: reason
      }
    )
    true
  )
)

;; ===================================
;; PUBLIC FUNCTIONS - EMPLOYER MANAGEMENT
;; ===================================

;; Register as an employer
(define-public (register-employer 
  (company-name (string-ascii 100))
  (match-rate uint)
  (max-match-amount uint)
  (vesting-period-days uint)
)
  (let (
    (employer tx-sender)
    (existing-employer (map-get? employers { employer: employer }))
  )
    (asserts! (is-none existing-employer) ERR-EMPLOYER-NOT-FOUND)
    (asserts! (<= match-rate u100) ERR-INVALID-PARAMETERS)
    (asserts! (>= vesting-period-days MIN-VESTING-PERIOD) ERR-INVALID-PARAMETERS)
    (asserts! (<= vesting-period-days MAX-VESTING-PERIOD) ERR-INVALID-PARAMETERS)
    
    (map-set employers
      { employer: employer }
      {
        company-name: company-name,
        match-rate: match-rate,
        max-match-amount: max-match-amount,
        vesting-schedule: vesting-period-days,
        total-employees: u0,
        total-contributions: u0,
        is-active: true,
        registration-block: stacks-block-height
      }
    )
    (ok true)
  )
)

;; Add employee to employer
(define-public (add-employee (employee principal))
  (let (
    (employer tx-sender)
    (employer-data (unwrap! (map-get? employers { employer: employer }) ERR-EMPLOYER-NOT-FOUND))
    (existing-relationship (map-get? employee-employer { employee: employee }))
  )
    (asserts! (get is-active employer-data) ERR-ACCOUNT-SUSPENDED)
    (asserts! (is-none existing-relationship) ERR-INVALID-PARAMETERS)
    
    ;; Create employee-employer relationship
    (map-set employee-employer
      { employee: employee }
      { employer: employer, start-date: stacks-block-height, is-active: true }
    )
    
    ;; Update employer employee count
    (map-set employers
      { employer: employer }
      (merge employer-data {
        total-employees: (+ (get total-employees employer-data) u1)
      })
    )
    
    ;; Update employee's vesting schedule if they have an account
    (match (map-get? retirement-accounts { participant: employee })
      account (map-set retirement-accounts
        { participant: employee }
        (merge account {
          vesting-start-block: stacks-block-height,
          vesting-period-days: (get vesting-schedule employer-data)
        })
      )
      true ;; Employee doesn't have account yet
    )
    
    (ok true)
  )
)

;; ===================================
;; READ-ONLY FUNCTIONS
;; ===================================

;; Get retirement account information
(define-read-only (get-account-info (participant principal))
  (match (map-get? retirement-accounts { participant: participant })
    account (let (
      (vested-employer-balance (calculate-vested-amount 
        (get employer-balance account)
        (get vesting-start-block account)
        (get vesting-period-days account)))
      (participant-age (calculate-age (get birth-year account)))
    )
      (ok {
        employee-balance: (get employee-balance account),
        employer-balance: (get employer-balance account),
        vested-employer-balance: vested-employer-balance,
        total-balance: (+ (get employee-balance account) vested-employer-balance),
        total-contributions: (get total-contributions account),
        total-employer-match: (get total-employer-match account),
        investment-pool: (get investment-pool account),
        account-status: (get account-status account),
        participant-age: participant-age,
        years-until-retirement: (if (>= participant-age MIN-RETIREMENT-AGE) u0 (- MIN-RETIREMENT-AGE participant-age)),
        annual-salary: (get annual-salary account),
        contribution-rate: (get contribution-rate account)
      })
    )
    ERR-ACCOUNT-NOT-FOUND
  )
)

;; Get employer information
(define-read-only (get-employer-info (employee principal))
  (map-get? employee-employer { employee: employee })
)

;; Get fund statistics
(define-read-only (get-fund-statistics)
  (ok {
    total-assets: (var-get total-assets),
    total-participants: (var-get total-participants),
    fund-inception-block: (var-get fund-inception-block),
    conservative-pool-return: (var-get conservative-pool-return),
    balanced-pool-return: (var-get balanced-pool-return),
    aggressive-pool-return: (var-get aggressive-pool-return)
  })
)

;; Get withdrawal history
(define-read-only (get-withdrawal-history (participant principal))
  (let (
    (withdrawal-0 (map-get? withdrawal-history { participant: participant, withdrawal-id: u0 }))
    (withdrawal-1 (map-get? withdrawal-history { participant: participant, withdrawal-id: u1 }))
    (withdrawal-2 (map-get? withdrawal-history { participant: participant, withdrawal-id: u2 }))
  )
    (list withdrawal-0 withdrawal-1 withdrawal-2)
  )
)

;; Calculate projected retirement balance
(define-read-only (calculate-projected-balance 
  (participant principal) 
  (additional-years uint)
  (annual-contribution uint)
)
  (match (map-get? retirement-accounts { participant: participant })
    account (let (
      (current-balance (+ (get employee-balance account) (get employer-balance account)))
      (investment-pool (get investment-pool account))
      (annual-return (get-pool-return-rate investment-pool))
      (total-future-contributions (* annual-contribution additional-years))
      (compound-growth (calculate-compound-interest current-balance annual-return (* additional-years u52560)))
    )
      (ok (+ current-balance total-future-contributions compound-growth))
    )
    ERR-ACCOUNT-NOT-FOUND
  )
)

;; Check if participant is eligible for retirement
(define-read-only (is-eligible-for-retirement (participant principal))
  (match (map-get? retirement-accounts { participant: participant })
    account (let (
      (participant-age (calculate-age (get birth-year account)))
    )
      (ok (>= participant-age MIN-RETIREMENT-AGE))
    )
    ERR-ACCOUNT-NOT-FOUND
  )
)

;; ===================================
;; ADMIN FUNCTIONS
;; ===================================

;; Update investment pool returns (admin only)
(define-public (update-pool-returns 
  (conservative-return uint) 
  (balanced-return uint) 
  (aggressive-return uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set conservative-pool-return conservative-return)
    (var-set balanced-pool-return balanced-return)
    (var-set aggressive-pool-return aggressive-return)
    (ok true)
  )
)

;; Set annual contribution limits (admin only)
(define-public (set-contribution-limits (year uint) (employee-limit uint) (catch-up-limit uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set annual-contribution-limits
      { year: year }
      { employee-limit: employee-limit, catch-up-limit: catch-up-limit }
    )
    (ok true)
  )
)

;; Initialize the fund (admin only, called once)
(define-public (initialize-fund)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (var-get fund-inception-block) u0) ERR-INVALID-PARAMETERS)
    (var-set fund-inception-block stacks-block-height)
    
    ;; Set initial contribution limits (2024)
    (try! (set-contribution-limits u2024 u23000 u7500)) ;; $23,000 + $7,500 catch-up
    
    ;; Initialize investment pools
    (map-set investment-pools
      { pool-type: CONSERVATIVE-POOL }
      { total-balance: u0, participant-count: u0, annual-return: u400, last-update-block: stacks-block-height }
    )
    (map-set investment-pools
      { pool-type: BALANCED-POOL }
      { total-balance: u0, participant-count: u0, annual-return: u700, last-update-block: stacks-block-height }
    )
    (map-set investment-pools
      { pool-type: AGGRESSIVE-POOL }
      { total-balance: u0, participant-count: u0, annual-return: u1000, last-update-block: stacks-block-height }
    )
    
    (ok true)
  )
)