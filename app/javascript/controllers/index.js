import { application } from "./application"

import NostrLoginController from "./nostr_login_controller"
application.register("nostr-login", NostrLoginController)

import ThemeController from "./theme_controller"
application.register("theme", ThemeController)

import MarkdownEditorController from "./markdown_editor_controller"
application.register("markdown-editor", MarkdownEditorController)

import ContentBuilderController from "./content_builder_controller"
application.register("content-builder", ContentBuilderController)

import AccountPairingController from "./account_pairing_controller"
application.register("account-pairing", AccountPairingController)

import MediaPreviewController from "./media_preview_controller"
application.register("media-preview", MediaPreviewController)

import PostSchedulerController from "./post_scheduler_controller"
application.register("post-scheduler", PostSchedulerController)

import LocalTimeController from "./local_time_controller"
application.register("local-time", LocalTimeController)

import ClipboardController from "./clipboard_controller"
application.register("clipboard", ClipboardController)

import MobileNavController from "./mobile_nav_controller"
application.register("mobile-nav", MobileNavController)

import InlineReplyController from "./inline_reply_controller"
application.register("inline-reply", InlineReplyController)

import InteractionActionsController from "./interaction_actions_controller"
application.register("interaction-actions", InteractionActionsController)

import InteractionsFilterController from "./interactions_filter_controller"
application.register("interactions-filter", InteractionsFilterController)

import AccountPickerController from "./account_picker_controller"
application.register("account-picker", AccountPickerController)

import ExpandableController from "./expandable_controller"
application.register("expandable", ExpandableController)

import BlossomUploadController from "./blossom_upload_controller"
application.register("blossom-upload", BlossomUploadController)

import FlashController from "./flash_controller"
application.register("flash", FlashController)

import DmFilterController from "./dm_filter_controller"
application.register("dm-filter", DmFilterController)

import DmThreadController from "./dm_thread_controller"
application.register("dm-thread", DmThreadController)

import DmComposerController from "./dm_composer_controller"
application.register("dm-composer", DmComposerController)

import DmDeliveryController from "./dm_delivery_controller"
application.register("dm-delivery", DmDeliveryController)

