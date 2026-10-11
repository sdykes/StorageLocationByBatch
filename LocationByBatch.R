library(tidyverse)

bin_batch |> group_by(BinID) |> summarise(s = sum(w)) |> filter(abs(s - 1) > 1e-9)   # should be empty
bin_batch |> count(BinID) |> count(n)   # expect 44,832 bins with 1 batch and 12 with 2
# with a true bin-level link, use:  tibble(BinID, GraderBatchID, w = 1)

# location mix per batch
batch_loc <- bin_main |>
  inner_join(bin_batch, by = c("BinID", "BinDeliveryID")) |>
  group_by(GraderBatchID, main_site, main_type, main_locn) |>
  summarise(bins = sum(w), .groups = "drop") |>
  group_by(GraderBatchID) |>
  mutate(frac_bins = bins / sum(bins)) |>
  ungroup()

batch_main <- batch_loc |>
  group_by(GraderBatchID) |>
  slice_max(frac_bins, n = 1, with_ties = FALSE) |>
  ungroup() |>
  mutate(main_locn_flag = if_else(frac_bins >= 0.5, main_locn, "Mixed"))

# continuous exposure per batch
batch_exposure <- bin_tot |>
  inner_join(bin_batch, by = "BinID") |>
  group_by(GraderBatchID) |>
  summarise(bins = sum(w),
            mean_days_in_store = weighted.mean(days_total, w),
            .groups = "drop")

batch_summary <- batch_main |>
  left_join(batch_exposure, by = "GraderBatchID")
