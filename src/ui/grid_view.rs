use crate::ui::state::{AppState, LibraryViewMode};
use eframe::egui;
use egui_extras::Column;

pub struct GridView;

impl GridView {
    pub fn show(ctx: &egui::Context, state: &mut AppState) {
        egui::CentralPanel::default().show(ctx, |ui| {
            // Toolbar
            ui.horizontal(|ui| {
                let loaded = state.songs.len();
                if state.loading_count > 0 {
                    ui.label(format!("{loaded} songs · loading {}…", state.loading_count));
                } else {
                    ui.label(format!("{loaded} songs"));
                }

                // Right-to-left layout: the first item sits at the far right.
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.button("\u{1F5D1} Clear All").clicked() {
                        state.songs.clear();
                        state.pending_changes = true;
                    }

                    ui.separator();

                    // View mode toggle, second from the right. Added
                    // right-to-left, so "Grid" comes first to keep the
                    // left-to-right reading order List → Grid.
                    let list_selected = state.library_view_mode == LibraryViewMode::List;
                    let grid_selected = state.library_view_mode == LibraryViewMode::Grid;

                    if ui.selectable_label(grid_selected, "🔲 Grid").clicked() {
                        state.library_view_mode = LibraryViewMode::Grid;
                    }
                    if ui.selectable_label(list_selected, "📋 List").clicked() {
                        state.library_view_mode = LibraryViewMode::List;
                    }

                    ui.separator();

                    // Live search filter; every keystroke narrows the table.
                    ui.add_sized(
                        [280.0, 24.0],
                        egui::TextEdit::singleline(&mut state.song_search)
                            .hint_text("Search song, Artist, Album, Year, Genre")
                            .desired_width(f32::INFINITY),
                    );
                });
            });

            ui.separator();

            if state.songs.is_empty() {
                ui.vertical_centered(|ui| {
                    ui.add_space(50.0);
                    if state.loading_count > 0 {
                        ui.label("Reading tags…");
                    } else {
                        ui.label("No songs added yet.");
                        ui.label("Add songs from the File menu to get started.");
                    }
                });
                return;
            }

            // Collect indices that were clicked; mutating the view after
            // rendering avoids borrow conflicts with the virtualised iterators.
            let mut clicked_idx = None;

            // Real song indices that pass the search filter, in library order.
            let visible = Self::visible_indices(state);

            match state.library_view_mode {
                LibraryViewMode::List => Self::show_list(ui, state, &visible, &mut clicked_idx),
                LibraryViewMode::Grid => Self::show_grid(ui, state, &visible, &mut clicked_idx),
            }

            if let Some(idx) = clicked_idx {
                state.open_song_detail(idx);
            }
        });
    }

    /// Indices of the songs matching the search box. An empty query lists
    /// every song. Matching is case-insensitive over the fields the filter
    /// advertises: title (or file name when untitled), artist, album, year,
    /// and genre.
    fn visible_indices(state: &AppState) -> Vec<usize> {
        let query = state.song_search.trim().to_lowercase();
        if query.is_empty() {
            return (0..state.songs.len()).collect();
        }
        state
            .songs
            .iter()
            .enumerate()
            .filter_map(|(idx, song)| {
                let title = if song.metadata.title.is_empty() {
                    song.file_name_str()
                } else {
                    song.metadata.title.as_str()
                };
                let matched = [
                    title,
                    song.metadata.artist.as_str(),
                    song.metadata.album.as_str(),
                    song.metadata.year.as_str(),
                    song.metadata.genre.as_str(),
                ]
                .into_iter()
                .any(|field| field.to_lowercase().contains(&query));
                matched.then_some(idx)
            })
            .collect()
    }

    fn show_list(
        ui: &mut egui::Ui,
        state: &mut AppState,
        visible: &[usize],
        clicked_idx: &mut Option<usize>,
    ) {
        let songs = &state.songs;

        egui_extras::TableBuilder::new(ui)
            .striped(true)
            .id_salt("song_table")
            .resizable(true)
            .cell_layout(egui::Layout::left_to_right(egui::Align::Center))
            .column(Column::auto().at_least(40.0))
            .column(Column::auto().at_least(200.0))
            .column(Column::auto().at_least(150.0))
            .column(Column::auto().at_least(150.0))
            .column(Column::auto().at_least(60.0))
            .column(Column::auto().at_least(100.0))
            .column(Column::auto().at_least(80.0))
            .header(20.0, |mut header| {
                for label in ["#", "Title", "Artist", "Album", "Year", "Genre", "Track"] {
                    header.col(|ui| {
                        ui.strong(label);
                    });
                }
            })
            .body(|body| {
                // `rows` only builds the visible rows, so a library of tens of
                // thousands of songs no longer creates every widget each frame.
                // `visible` maps rendered rows back to real song indices.
                body.rows(28.0, visible.len(), |mut row| {
                    let idx = visible[row.index()];
                    let song = &songs[idx];

                    row.col(|ui| {
                        ui.add(egui::Label::new((idx + 1).to_string()).selectable(false));
                        track_list_row_click(ui, idx, 0, clicked_idx);
                    });
                    row.col(|ui| {
                        let title = if song.metadata.title.is_empty() {
                            song.file_name_str()
                        } else {
                            song.metadata.title.as_str()
                        };
                        ui.add(egui::Label::new(title).selectable(false));
                        track_list_row_click(ui, idx, 1, clicked_idx);
                    });
                    row.col(|ui| {
                        ui.add(egui::Label::new(&song.metadata.artist).selectable(false));
                        track_list_row_click(ui, idx, 2, clicked_idx);
                    });
                    row.col(|ui| {
                        ui.add(egui::Label::new(&song.metadata.album).selectable(false));
                        track_list_row_click(ui, idx, 3, clicked_idx);
                    });
                    row.col(|ui| {
                        ui.add(egui::Label::new(&song.metadata.year).selectable(false));
                        track_list_row_click(ui, idx, 4, clicked_idx);
                    });
                    row.col(|ui| {
                        ui.add(egui::Label::new(&song.metadata.genre).selectable(false));
                        track_list_row_click(ui, idx, 5, clicked_idx);
                    });
                    row.col(|ui| {
                        let track = if song.metadata.track_number.is_empty() {
                            "—".to_string()
                        } else if song.metadata.total_tracks.is_empty() {
                            song.metadata.track_number.clone()
                        } else {
                            format!(
                                "{}/{}",
                                song.metadata.track_number, song.metadata.total_tracks
                            )
                        };
                        ui.add(egui::Label::new(track).selectable(false));
                        track_list_row_click(ui, idx, 6, clicked_idx);
                    });
                });
            });
    }

    fn show_grid(
        ui: &mut egui::Ui,
        state: &mut AppState,
        visible: &[usize],
        clicked_idx: &mut Option<usize>,
    ) {
        const TILE_WIDTH: f32 = 112.0;
        const TILE_SPACING: f32 = 12.0;
        const ROW_HEIGHT: f32 = 126.0;

        let columns =
            (((ui.available_width() + TILE_SPACING) / (TILE_WIDTH + TILE_SPACING)).floor()
                as usize)
                .max(1);
        let row_count = visible.len().div_ceil(columns);

        // Split the borrows: the song list is read-only while the texture cache
        // is mutated. This avoids cloning artwork or titles for every tile.
        let songs = &state.songs;
        let textures = &mut state.album_art_textures;

        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show_rows(ui, ROW_HEIGHT, row_count, |ui, row_range| {
                for row in row_range {
                    ui.horizontal(|ui| {
                        for column in 0..columns {
                            // `visible` maps tile slots back to real song
                            // indices, so the search filter applies here too.
                            let Some(&idx) = visible.get(row * columns + column) else {
                                break;
                            };
                            let Some(song) = songs.get(idx) else {
                                break;
                            };

                            ui.allocate_ui_with_layout(
                                egui::vec2(TILE_WIDTH, ROW_HEIGHT),
                                egui::Layout::top_down(egui::Align::Center),
                                |ui| {
                                    let icon_clicked = if let Some(art) = &song.metadata.album_art {
                                        match textures.get_or_load(ui.ctx(), art, 96) {
                                            Some(texture) => ui
                                                .add_sized(
                                                    [72.0, 72.0],
                                                    egui::Image::new(&texture)
                                                        .fit_to_exact_size(egui::vec2(72.0, 72.0)),
                                                )
                                                .interact(egui::Sense::click())
                                                .on_hover_cursor(egui::CursorIcon::PointingHand)
                                                .clicked(),
                                            None => button_placeholder(ui),
                                        }
                                    } else {
                                        button_placeholder(ui)
                                    };

                                    if icon_clicked {
                                        *clicked_idx = Some(idx);
                                    }

                                    let title = if song.metadata.title.is_empty() {
                                        song.file_name_str()
                                    } else {
                                        song.metadata.title.as_str()
                                    };
                                    let label = ui.add_sized(
                                        [TILE_WIDTH, 36.0],
                                        egui::Label::new(title).truncate().wrap().selectable(false),
                                    );
                                    if label
                                        .on_hover_cursor(egui::CursorIcon::PointingHand)
                                        .clicked()
                                    {
                                        *clicked_idx = Some(idx);
                                    }
                                },
                            );
                        }
                    });
                }
            });
    }
}

fn button_placeholder(ui: &mut egui::Ui) -> bool {
    ui.add_sized(
        [72.0, 72.0],
        egui::Button::new(egui::RichText::new("♫").size(42.0)),
    )
    .clicked()
}

fn track_list_row_click(
    ui: &mut egui::Ui,
    song_index: usize,
    column_index: usize,
    clicked_idx: &mut Option<usize>,
) {
    let cell = ui.interact(
        ui.max_rect(),
        ui.id().with(("song_list_cell", song_index, column_index)),
        egui::Sense::click(),
    );
    // Hand cursor over clickable songs; the labels are non-selectable so the
    // text-selection pass cannot override this with the text cursor.
    if cell
        .on_hover_cursor(egui::CursorIcon::PointingHand)
        .clicked()
    {
        *clicked_idx = Some(song_index);
    }
}
