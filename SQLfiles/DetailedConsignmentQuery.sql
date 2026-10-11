/* ------------------------------------------------------------
   1. Dwell time per bin per location (tipped bins only)
   ------------------------------------------------------------ */
DROP TABLE IF EXISTS #bin_loc;

WITH ev AS (
    SELECT
         bht.BinID
        ,bht.BinDeliveryID
        ,bht.HistoryDateTime
        ,bht.LastAction
        ,bht.TippedDatetime
        ,cts.CompanyName AS StorageSite
        ,CASE WHEN bd.StorageTypeID = 4 THEN 'CA' ELSE 'RA' END AS StorageType
        ,lt.LocnDesc AS StorageLocn
        ,lrt.[Row]   AS StorageRow
        -- two rows are written per move at the same timestamp: keep the later one
        ,ROW_NUMBER() OVER (
            PARTITION BY bht.BinID, bht.HistoryDateTime
            ORDER BY bht.CreatedDateTime DESC      -- <- swap for the history table's identity/PK column if it has one
         ) AS rn
    FROM dbo.ma_Bin_HistoryT AS bht
    LEFT JOIN ma_Bin_DeliveryT  AS bd  ON bd.BinDeliveryID = bht.BinDeliveryID
    LEFT JOIN sw_Location_RowT  AS lrt ON lrt.LocnRowID    = bht.LocationRowID
    LEFT JOIN sw_LocationT      AS lt  ON lt.LocnID        = lrt.LocnID
    LEFT JOIN sw_CompanyT       AS cts ON cts.CompanyID    = bht.StorageSiteCompanyID
    WHERE bht.CreatedDateTime > '2026-01-01 00:00:00.000'
),
dedup AS (
    SELECT *,
           MIN(TippedDatetime) OVER (PARTITION BY BinID) AS FirstTip
    FROM ev
    WHERE rn = 1
),
trimmed AS (        -- tipped bins only, ignore anything after the first tip (returned-from-grader bins)
    SELECT *,
           LEAD(HistoryDateTime) OVER (PARTITION BY BinID ORDER BY HistoryDateTime) AS NextDT
    FROM dedup
    WHERE FirstTip IS NOT NULL
      AND HistoryDateTime <= FirstTip
),
intervals AS (
    SELECT
         BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn, StorageRow
        ,DATEDIFF(SECOND,
                  HistoryDateTime,
                  COALESCE(NextDT, HistoryDateTime)   -- last row (the tip) has zero duration
         ) / 86400.0 AS Days
    FROM trimmed
)
SELECT
     BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn, StorageRow
    ,SUM(Days) AS Days
INTO #bin_loc
FROM intervals
GROUP BY BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn, StorageRow;

CREATE CLUSTERED INDEX ix_bin_loc ON #bin_loc (BinID);


/* ------------------------------------------------------------
   2. Dominant storage location per BIN
      (ignores no-location time and Smartfresh treatment rooms)
   ------------------------------------------------------------ */
WITH room AS (          -- roll up to room level (drop StorageRow)
    SELECT BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn, SUM(Days) AS Days
    FROM #bin_loc
    GROUP BY BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn
),
tot AS (
    SELECT BinID, SUM(Days) AS DaysTotal
    FROM #bin_loc
    GROUP BY BinID
),
ranked AS (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY r.BinID ORDER BY r.Days DESC, r.StorageLocn) AS rk
    FROM room r
    WHERE r.StorageLocn IS NOT NULL
      AND r.StorageLocn NOT LIKE '%Smartfresh%'
)
SELECT
     k.BinID
    ,k.BinDeliveryID
    ,k.StorageSite  AS MainSite
    ,k.StorageType  AS MainType
    ,k.StorageLocn  AS MainLocn
    ,k.Days         AS MainDays
    ,t.DaysTotal
    ,k.Days / NULLIF(t.DaysTotal, 0) AS FracInMain
FROM ranked k
JOIN tot    t ON t.BinID = k.BinID
WHERE k.rk = 1;


/* ------------------------------------------------------------
   3. Dominant storage location per CONSIGNMENT (BinDeliveryID)
      = location with the most bin-days
   ------------------------------------------------------------ */
WITH room AS (
    SELECT BinDeliveryID, StorageSite, StorageType, StorageLocn, SUM(Days) AS BinDays
    FROM #bin_loc
    WHERE StorageLocn IS NOT NULL
      AND StorageLocn NOT LIKE '%Smartfresh%'
    GROUP BY BinDeliveryID, StorageSite, StorageType, StorageLocn
),
ranked AS (
    SELECT room.*,
           SUM(BinDays) OVER (PARTITION BY BinDeliveryID) AS BinDaysTotal,
           ROW_NUMBER() OVER (PARTITION BY BinDeliveryID ORDER BY BinDays DESC, StorageLocn) AS rk
    FROM room
)
SELECT
     BinDeliveryID
    ,StorageSite AS MainSite
    ,StorageType AS MainType
    ,StorageLocn AS MainLocn
    ,BinDays
    ,BinDays / NULLIF(BinDaysTotal, 0) AS FracInMain
FROM ranked
WHERE rk = 1;