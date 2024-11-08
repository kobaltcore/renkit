clippy:
	cargo clippy -- -W clippy::pedantic -A clippy::too_many_lines -A clippy::match_bool -A clippy::missing_errors_doc -A clippy::missing_panics_doc -A clippy::cast_possible_truncation -A clippy::should_implement_trait -A clippy::fn_params_excessive_bools -A clippy::too_many_arguments -A clippy::module_name_repetitions

clippy-fix:
	cargo clippy --fix -- -W clippy::pedantic -A clippy::too_many_lines -A clippy::match_bool -A clippy::missing_errors_doc -A clippy::missing_panics_doc -A clippy::cast_possible_truncation -A clippy::should_implement_trait -A clippy::fn_params_excessive_bools -A clippy::too_many_arguments -A clippy::module_name_repetitions
