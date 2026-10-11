library(tidyverse)

con <- DBI::dbConnect(odbc::odbc(),    
                      Driver = "ODBC Driver 18 for SQL Server", 
                      Server = "abcrepldb.database.windows.net",  
                      Database = "ABCPackerRepl",   
                      UID = "abcadmin",   
                      PWD = "Trauts2018!",
                      Port = 1433
)

BinLocations <- DBI::dbGetQuery(con,
                                "SELECT 
	bht.HistoryBinID
	,bht.BinID
	,bht.BinNo
	,bht.BinDeliveryID
	,bht.GraderBatchID
	,bht.HistoryDateTime
	,cts.CompanyName AS StorageSite
	,CASE
		WHEN bd.StorageTypeID = 4 THEN 'CA'
		ELSE 'RA'
	END AS StorageType
	,lt.LocnDesc AS StorageLocn
	,lrt.Row AS StorageRow 
	,bht.LastAction
FROM ma_Bin_HistoryT AS bht
INNER JOIN
	(
	SELECT 
		BinID
	FROM ma_BinT AS bn
	LEFT JOIN
		ma_Grader_BatchT AS gb
	ON gb.GraderBatchID = bn.GraderBatchID
	LEFT JOIN 
		(
		SELECT 
			GraderBatchID
			,MIN(CreatedDateTime) AS FirstClosedDateTime
		FROM ma_Grader_Batch_ChargeT
		WHERE Side = 'DR'
		GROUP BY GraderBatchID
		) AS fc 
	ON fc.GraderBatchID = bn.GraderBatchID
	WHERE bn.GraderBatchID IS NOT NULL
	AND gb.SeasonID = 2013
	AND gb.PackingCompanyID = 1 -- Filter by Packing site = Te Ipu
	AND fc.GraderBatchID IS NOT NULL -- Filter only batches that have been closed once
	AND bn.BinDamageID IS NULL -- Filter damaged bins
	) AS fb
ON fb.BinID = bht.BinID
LEFT JOIN
	ma_Bin_DeliveryT AS bd
ON bd.BinDeliveryID = bht.BinDeliveryID
LEFT JOIN
	sw_Location_RowT AS lrt
ON lrt.LocnRowID = bht.LocationRowID
LEFT JOIN
	sw_LocationT AS lt
ON lt.LocnID = lrt.LocnID
LEFT JOIN
	sw_CompanyT AS cts
ON cts.CompanyID = bht.StorageSiteCompanyID
ORDER BY bht.BinID, bht.HistoryDateTime")

BDToGBMapping <- DBI::dbGetQuery(con, 
                                 "SELECT 
	bu.BinDeliveryID
	,bu.GraderBatchID
	,gb.GraderBatchNo
	,ctp.CompanyName AS Packing_site
FROM ma_Bin_UsageT AS bu
LEFT JOIN
	ma_Bin_DeliveryT AS bd
ON bd.BinDeliveryID = bu.BinDeliveryID
LEFT JOIN
	ma_Grader_BatchT AS gb
ON gb.GraderBatchID = bu.GraderBatchID
/* Modified batch closure based on if the batch has ever been closed */
LEFT JOIN 
	(
    SELECT 
		GraderBatchID
		,MIN(CreatedDateTime) AS FirstClosedDateTime
    FROM ma_Grader_Batch_ChargeT
    WHERE Side = 'DR'
    GROUP BY GraderBatchID
	) AS fc 
ON fc.GraderBatchID = bu.GraderBatchID
LEFT JOIN
	sw_CompanyT AS ctp
ON ctp.CompanyID = gb.PackingCompanyID
WHERE bu.GraderBatchID IS NOT NULL -- Must have a GraderBatchID allocated
AND bd.PresizeFlag = 0 -- Only Production runs
AND bd.SeasonID = 2013 -- Only fruit from 2026 Season
AND gb.PackingCompanyID = 1 -- Only Te Ipu Batches
AND fc.GraderBatchID IS NOT NULL -- Apply the new batch closure filter")

DBI::dbDisconnect(con)

write_csv(BinLocations,"BinLocations.csv")
#write_csv(BDToGBMapping,"BDToGBMapping.csv")

own_sites <- c("Poporo Way", "Te Ipu Packhouse (RO)")

ev_all <- BinLocations |>
  mutate(t = ymd_hms(HistoryDateTime),
         is_tip = str_detect(LastAction, "was tipped"),
         StorageLocn = if_else(is.na(StorageLocn) & !StorageSite %in% own_sites,
                               StorageSite, StorageLocn))

# bin -> batch straight from the tip rows; 12 two-batch bins split 50:50
bin_batch <- ev_all |>
  filter(is_tip, !is.na(GraderBatchID)) |>
  distinct(BinID, BinDeliveryID, GraderBatchID) |>
  group_by(BinID) |>
  mutate(w = 1 / n()) |>
  ungroup()

# dwell times as before, starting from ev_all
ev <- ev_all |>
  arrange(BinID, t) |>
  group_by(BinID, t) |> slice_tail(n = 1) |> ungroup() |>
  group_by(BinID) |>
  mutate(first_tip_t = suppressWarnings(min(t[is_tip])),
         tipped = is.finite(first_tip_t)) |>
  filter(tipped, t <= first_tip_t) |>
  mutate(next_t = lead(t),
         end = coalesce(next_t, t),
         days = as.numeric(difftime(end, t, units = "days"))) |>
  ungroup()

# time per bin per location
bin_loc <- ev |>
  filter(tipped) |>
  group_by(BinID, BinDeliveryID, StorageSite, StorageType, StorageLocn) |>
  summarise(days = sum(days), .groups = "drop")

# total time in store per bin (denominator)
bin_tot <- bin_loc |> group_by(BinID) |> summarise(days_total = sum(days))

# dominant storage location per bin (ignoring no-location and Smartfresh)
bin_main <- bin_loc |>
  filter(!is.na(StorageLocn), !str_detect(StorageLocn, "Smartfresh")) |>
  group_by(BinID) |>
  slice_max(days, n = 1, with_ties = FALSE) |>
  ungroup() |>
  left_join(bin_tot, by = "BinID") |>
  mutate(frac_in_main = days / days_total) |>
  rename(main_site = StorageSite, main_type = StorageType,
         main_locn = StorageLocn, main_days = days)

# consignment level: location with the most bin-days
delivery_main <- bin_loc |>
  filter(!is.na(StorageLocn), !str_detect(StorageLocn, "Smartfresh")) |>
  group_by(BinDeliveryID, StorageSite, StorageType, StorageLocn) |>
  summarise(no_of_bins = n(),
            mean_bin_days = mean(days), .groups = "drop") |>
  group_by(BinDeliveryID) |>
  slice_max(mean_bin_days, n = 1, with_ties = FALSE)
