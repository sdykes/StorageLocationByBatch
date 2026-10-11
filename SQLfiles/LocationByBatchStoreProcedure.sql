CREATE OR ALTER PROCEDURE dbo.usp_Refresh_BatchStorage
     @SeasonID         int = 2013
    ,@PackingCompanyID int = 1
AS
BEGIN
    SET NOCOUNT ON;

    /* STEP 1: history for the in-scope bins */
    DROP TABLE IF EXISTS #hist;
    SELECT
         bht.HistoryBinID, bht.BinID, bht.BinNo, bht.BinDeliveryID, bht.GraderBatchID
        ,bht.HistoryDateTime
        ,cts.CompanyName AS StorageSite
        ,CASE WHEN bd.StorageTypeID = 4 THEN 'CA' ELSE 'RA' END AS StorageType
        ,lt.LocnDesc AS StorageLocn
        ,lrt.[Row] AS StorageRow
        ,bht.LastAction
    INTO #hist
    FROM ma_Bin_HistoryT AS bht
    INNER JOIN (
        SELECT BinID
        FROM ma_BinT AS bn
        LEFT JOIN ma_Grader_BatchT AS gb ON gb.GraderBatchID = bn.GraderBatchID
        LEFT JOIN (
            SELECT GraderBatchID, MIN(CreatedDateTime) AS FirstClosedDateTime
            FROM ma_Grader_Batch_ChargeT
            WHERE Side = 'DR'
            GROUP BY GraderBatchID
        ) AS fc ON fc.GraderBatchID = bn.GraderBatchID
        WHERE bn.GraderBatchID IS NOT NULL
          AND gb.SeasonID = @SeasonID
          AND gb.PackingCompanyID = @PackingCompanyID
          AND fc.GraderBatchID IS NOT NULL
          AND bn.BinDamageID IS NULL
    ) AS fb ON fb.BinID = bht.BinID
    LEFT JOIN ma_Bin_DeliveryT AS bd  ON bd.BinDeliveryID = bht.BinDeliveryID
    LEFT JOIN sw_Location_RowT AS lrt ON lrt.LocnRowID    = bht.LocationRowID
    LEFT JOIN sw_LocationT     AS lt  ON lt.LocnID        = lrt.LocnID
    LEFT JOIN sw_CompanyT      AS cts ON cts.CompanyID    = bht.StorageSiteCompanyID;

    /* STEP 2: days per bin per location, up to the first tip row */
    DROP TABLE IF EXISTS #bin_loc;
    WITH tip AS (
        SELECT BinID, MIN(HistoryBinID) AS FirstTipID
        FROM #hist
        WHERE LastAction LIKE '%was tipped%'
        GROUP BY BinID
    ),
    trimmed AS (
        SELECT h.*,
               ROW_NUMBER() OVER (PARTITION BY h.BinID, h.HistoryDateTime
                                  ORDER BY h.HistoryBinID DESC) AS rn
        FROM #hist h
        JOIN tip t ON t.BinID = h.BinID AND h.HistoryBinID <= t.FirstTipID
    ),
    dedup AS (
        SELECT BinID, BinDeliveryID, HistoryBinID, HistoryDateTime, StorageSite, StorageType,
               CASE WHEN StorageLocn IS NULL
                     AND StorageSite NOT IN ('Poporo Way', 'Te Ipu Packhouse (RO)')
                    THEN StorageSite ELSE StorageLocn END AS StorageLocn
        FROM trimmed
        WHERE rn = 1
    ),
    nxt AS (
        SELECT *,
               LEAD(HistoryDateTime) OVER (PARTITION BY BinID
                                           ORDER BY HistoryDateTime, HistoryBinID) AS NextDT
        FROM dedup
    ),
    intervals AS (
        SELECT BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn,
               DATEDIFF(SECOND, HistoryDateTime, COALESCE(NextDT, HistoryDateTime)) / 86400.0 AS Days
        FROM nxt
    )
    SELECT BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn, SUM(Days) AS Days
    INTO #bin_loc
    FROM intervals
    GROUP BY BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn;

    CREATE CLUSTERED INDEX ix_bin_loc ON #bin_loc (BinID);

    /* STEP 3: bin -> batch (weights sum to 1 per bin) */
    DROP TABLE IF EXISTS #bin_batch;
    SELECT BinID, BinDeliveryID, GraderBatchID,
           1.0 / COUNT(*) OVER (PARTITION BY BinID) AS w
    INTO #bin_batch
    FROM (SELECT DISTINCT BinID, BinDeliveryID, GraderBatchID
          FROM #hist
          WHERE GraderBatchID IS NOT NULL
            AND LastAction LIKE '%was tipped%') x;

    /* STEP 4: main location per bin */
    DROP TABLE IF EXISTS #bin_main;
    WITH tot AS (
        SELECT BinID, SUM(Days) AS DaysTotal FROM #bin_loc GROUP BY BinID
    ),
    ranked AS (
        SELECT l.*,
               ROW_NUMBER() OVER (PARTITION BY l.BinID ORDER BY l.Days DESC, l.StorageLocn) AS rk
        FROM #bin_loc l
        WHERE l.StorageLocn IS NOT NULL
          AND l.StorageLocn NOT LIKE '%Smartfresh%'
    )
    SELECT k.BinID, k.BinDeliveryID,
           k.StorageSite AS MainSite, k.StorageType AS MainType, k.StorageLocn AS MainLocn,
           k.Days AS MainDays, t.DaysTotal,
           k.Days / NULLIF(t.DaysTotal, 0) AS FracInMain
    INTO #bin_main
    FROM ranked k
    JOIN tot t ON t.BinID = k.BinID
    WHERE k.rk = 1;

    /* STEP 5: batch-level result, replace this season's rows atomically */
    BEGIN TRANSACTION;

    DELETE FROM dbo.rpt_BatchStorage WHERE SeasonID = @SeasonID;

    WITH s AS (
        SELECT bb.GraderBatchID, bm.MainSite, bm.MainType, bm.MainLocn, SUM(bb.w) AS Bins
        FROM #bin_main bm
        JOIN #bin_batch bb ON bb.BinID = bm.BinID
        GROUP BY bb.GraderBatchID, bm.MainSite, bm.MainType, bm.MainLocn
    ),
    r AS (
        SELECT *,
               Bins / SUM(Bins) OVER (PARTITION BY GraderBatchID) AS FracBins,
               ROW_NUMBER() OVER (PARTITION BY GraderBatchID ORDER BY Bins DESC, MainLocn) AS rk
        FROM s
    ),
    expo AS (
        SELECT bb.GraderBatchID, SUM(bb.w) AS Bins,
               SUM(t.DaysTotal * bb.w) / SUM(bb.w) AS MeanDaysInStore
        FROM #bin_batch bb
        JOIN (SELECT BinID, SUM(Days) AS DaysTotal FROM #bin_loc GROUP BY BinID) t
          ON t.BinID = bb.BinID
        GROUP BY bb.GraderBatchID
    )
    INSERT INTO dbo.rpt_BatchStorage
        (SeasonID, GraderBatchID, MainSite, MainType, MainLocn, FracBins, MainLocnFlag, Bins, MeanDaysInStore)
    SELECT @SeasonID, r.GraderBatchID, r.MainSite, r.MainType, r.MainLocn, r.FracBins,
           CASE WHEN r.FracBins >= 0.5 THEN r.MainLocn ELSE 'Mixed' END,
           e.Bins, e.MeanDaysInStore
    FROM r
    JOIN expo e ON e.GraderBatchID = r.GraderBatchID
    WHERE r.rk = 1;

    COMMIT TRANSACTION;
END;