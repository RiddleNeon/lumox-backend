# lumox-backend

this is the backend of my app [Lumox](https://github.com/RiddleNeon/lumox).
it uses a postgreSQL database hosted on supabase.

this repo only contains the public schema of the database, the private schema is not included for security reasons. if you want to see the private schema, you can contact me.

you can find the sql queries for creating the tables, functions and triggers in the [`supabase_schema_public.sql`](supabase_schema_public.sql) file. Since the file is about 5.7k lines long, i will give you a quick overview of the structure of the database and the most important tables and functions here:

# Tables

## user related
- `profiles`: contains user profile information such as username, bio, profile picture, etc.
- `pro_users`: contains pro users and their subscription information.
- `ai_bots`: contains information about AI bots that can be used in conversations. this includes the bots user id and system prompt.
- `profile_settings`: contains user settings such as preferences, privacy settings, etc. 
- `user_streaks`: contains the streak information of every user. this contains the current streak count, the last date the streak was updated and the longest streak.
 
## messaging
- `messages`: contains messages sent in conversations.
- `message_versions`: contains versions of messages that have been edited. Every message has stored its initial version, and every time its edited, a new version is created in this table. if a message is deleted, it only adds a new version telling the system it is now deleted. this way we can keep track of all changes to messages and also restore deleted messages if needed.
- `conversations`: contains information about conversations between users. it contains the type of the conversation (currently ony "direct" and "direct-ai"), the title, the creation date and the last message date.
- `conversation_members`: contains information about which user is a member of which conversation. this is used to determine who can see which conversations and also to send notifications to users when they receive a new message in a conversation they are a member of.

## videos and tags
- `videos`: contains information about videos that have been added to the platform.
- `video_tags`: contains the tags associated with each video.
- `tags`: contains all available tags that can be associated with videos.

## interactions
- `likes`: contains information about which user liked which video.
- `dislikes`: contains information about which user disliked which video.
- `saved_videos`: contains information about which user saved which video.
- `follows`: contains information about which user follows which other user.
- `user_interactions`: contains information about various interactions a user has made. it currently only tracks video views, but it can be extended to track other interactions as well.

---

## quests
### quests
- `quests`: contains information about quests created by users. this only stores a bare minimum of information about quests, such as the creator and creation date. all the actual content of quests is stored in the `quest_versions` table. these quests only serve as a way to group different versions of quests together. if the quest is deleted, all quest versions are also deleted. however, if a quest version is deleted, the quest itself is not deleted, and it will just point to the next latest version of the quest. You can see a row of the `quests` table as a quest "controller" that controls the lifecycle of all versions of a quest. However, the actual data is stored in the `quests_latest` and `quest_versions` tables.
- `quests_latest`: contains the latest version of each quest. every time a new version of a quest is published, this table is updated to point to the new version.
- `quest_versions`: contains all versions of quests. every time you want to update a quest, you create a new version in this table and then update the `quests_latest` table to point to the new version. this way we can keep track of all changes to quests and also go back to any point in time and see how the quest system looked like at that time. Users have only write access to the `quest_versions` table, so that they cant destroy anything without a way of reverting it.
### connections
- `quest_connections`: just like the quests tables, this table only acts as a controller for quest connections, which are stored in the `quest_connection_versions` table. a quest connection is a connection between two quests that indicates that one quest is somehow related to the other quest. you can set the connection type yourself. for example, you can set a connection type of "prerequisite" to indicate that one quest is a prerequisite for another quest.
- `quest_connections_latest`: contains the latest version of each quest connection. just like the `quests_latest` table, this table is automatically updated to contain all the latest versions.
- `quest_connection_versions`: contains all versions of quest connections. i think you already get the concept :)
### dictionary helpers
- `quest_title_aliases`: contains aliases for quest titles. Ive implemented a dictionary, where every entry is a quest title with its corresponding description acting as an explanation. However a lot of terms have multiple names, so this table serves as a way to store all the different aliases for quest titles. this way we can easily search for quests by their title or any of their aliases.

## comments
- `comments`: contains comments made by users on videos.
- `comment_likes`: contains information about which user liked which comment.

## themes
- `themes`: contains information about themes created by users. they store theme colors and some properties like border radius, font, etc. a theme can be public or private. if its private, only the creator can add it to their collection, but if its public, anyone can add it to their collection.
- `applied_themes`: contains information about which user has which theme applied (activated). 
- `saved_themes`: contains information about which user saved which theme. saved means that the user has saved the theme to their collection, but it is not necessarily activated. 
- `theme_likes`: contains information about which user liked which theme.
- `theme_comments`: contains comments made by users on themes. currently not implemented in the frontend.


## currently unused
### miscellaneous
- `profile_quest_progress`: the idea is to track the progress of each user in each quest. this way we can show users how far they are in a quest and also give them rewards for completing quests.
- `profile_levels`: since users can complete quests they should also get a reward. i planned on doing that by giving users experience points to level up. 
- `categories`: i thought about giving quests categories (or rather tags since they can have multiple) to make it easier for users to find quests they are interested in and give levels in those categories. but i havent implemented that yet.
### tasks
i started implementing a task / quiz system that allows users to create tasks (again, with a version control system XD) and let them use a json-based schema to create unique quizzes and tasks. however, this system is still in its early stages and is currently not used anywhere in the app, so i decided to leave it out of the main user flow for now. but the tables are still there if you want to take a look at them. look at the branch [quiz-creation](https://github.com/RiddleNeon/lumox/tree/quiz_creation) if you want to see how the quiz creation system looks like in the app. note that i havent put much effort into the frontend of the quiz creation system, so it looks pretty bad, but it should give you an idea of how the system works.

- `tasks`: contains information about tasks created by users
- `task_versions`: contains all versions of tasks. 
- `task_attempts`: contains information about each attempt a user makes to solve a task. this way we can track how many attempts a user has made and also show them their previous attempts and results.
- `task_solves`: contains information about which user solved which task and when. 
- `task_solutions`: contains the solutions to tasks. the creator / contributors can add verified solutions to tasks, so that the system can use them to evaluate user submissions and also show them as hints if they are struggling with a task.

## moderation
- `user_warnings`: every time a user violates the community guidelines, a warning is added to this table. if a user accumulates too many warnings, they can be banned from the platform.
- `video_reports`: contains reports made by users on videos that violate the community guidelines. these reports can be reviewed by moderators to take appropriate action, such as removing the video or banning the user who posted the video. you can currently not report videos in the frontend.
- `ban_appeals`: contains appeals made by users who have been banned from the platform. users can submit an appeal to explain their situation and request to be unbanned. these appeals can be reviewed by moderators to decide whether to lift the ban or not. currently a user automatically gets unbanned after they submit a ban appeal. note that this is only temporary to prove the concept.
- `banned_words`: contains a list of words that are banned on the platform. if a message contains any of these words, it will be automatically deleted and the user will receive a warning. since the platform is built for minors, the list is pretty extensive and currently includes about 2500 words. it also includes intentionally misspelled words and variations of words to make it harder for users to bypass the filter.


# Functions
there are a lot of functions and not all of them are relevant, so i will just go over the essential ones.
## conversation functions
- `create_conversation`: creates a new conversation between users. it takes the type of the conversation (currently only "direct" and "direct-ai"), the receiver's user id and the title.
- `send_message`: sends a message in a conversation. it automatically checks for banned words and deletes the message if it contains any, and also adds a warning to the user. it also updates the last message date of the conversation and refreshes the last message preview.
- `delete_message`: deletes a message by adding a new version of the message with a deleted flag. this way we can keep track of deleted messages and also restore them if needed.
- `edit_message`: edits a message. also checks for banned words.
- `get_conversation_bot`: if the conversation is a "direct-ai" conversation
- `is_conversation_member`: checks if a user is a member of a conversation.
- `moderate_message`: this is a trigger function that is called every time a message is inserted or updated. it checks if the message contains any banned words and deletes the message if it does, and also cancels the message update / insertion and adds a warning to the user.

## video and tag functions
- `get_new_videos`: gets the newest videos added to the platform. it can also filter videos based on a cursor (timestamp) and whether to only show unseen videos for the user. 
- `get_trending_candidates`: gets videos that are trending based on a combination of factors such as the number of likes, views, and the rate at which they are gaining interactions. it also takes into account the age of the video to give newer videos a chance to trend. like get_new_videos, it can also filter videos based on a cursor (timestamp) and whether to only show unseen videos for the user.
- `get_videos_by_tag`: gets videos associated with a specific tag. 

## interaction functions
- `toggle_like`: toggles the like status of a video for a user. 
- `toggle_dislike`: toggles the dislike status of a video for a user.
- `toggle_follow`: toggles the follow status of another user for a user.
- `increment_video_metric`: increments a specific metric (such as views) for a video by a certain delta. this is used to track video views and other interactions. non-admin users can only increment the views metric, and they can only increment it by 1, while admin users can increment any metric by any delta. this is to prevent abuse of the system.
- `toggle_like_comment`: toggles the like status of a comment for a user.
- `toggle_theme_like`: toggles the like status of a theme for a user.

## quest functions
- `sync_quests_latest`: this is a trigger function that is called every time a new version of a quest is inserted. it applies the patch of the new quest version rows to the `quests_latest` table so that its data is always up to date.
- `sync_quest_connections_latest`: this is basically the same as `sync_quests_latest`, but for quest connections.

## comment functions
- `post_comment`: posts a comment on a video. it also checks if the comment is a reply to another comment and sets the parent_id accordingly. it returns the id of the new comment. just like `send_message`, it also checks for banned words.
- `get_comments_with_like`: gets comments for a video along with the like status for a specific user. it also supports pagination through limit and offset parameters.
- `toggle_like_comment`: toggles the like status of a comment for a user. it returns the new like status after toggling.

## other functions
- `contains_banned_word`: checks if a given content contains any banned words.
- `is_current_user_admin`: checks if the current user is an admin. 
- `is_pro`: checks if a user is a pro user.
- `request_pro_tier`: allows a user to request to become a pro user. it takes a key as an argument, which is a secret key that only the admin knows. if the key is correct, the user is added to the pro_users table and becomes a pro user.
- `request_streak_update`: this function is called when a user interacts with a video after opening the app. it checks if the user's streak should be updated based on the last time they updated their streak and the current date. if the user has a streak and they have interacted with a video on a different day than the last time they updated their streak, their streak is incremented by 1. if they have interacted with a video on the same day, their streak is not updated. if they have not interacted with any videos for more than 1 day, their streak is reset to 0. if the users streak is higher than their longest streak, their longest streak is also updated.


i think the rest of the functions are pretty self-explanatory based on their names, but if you have any questions about any specific function, feel free to ask me.
```
__create_conversation(p_type text, p_title text DEFAULT NULL::text) -> bigint -- (outdated, use the one with receiver_id instead)
_get_comments_with_like(p_video_id bigint, p_current_user uuid, p_parent_id bigint, p_limit integer, p_offset integer) -> record
_increment_video_metric(p_video_id bigint, p_column text, p_delta integer) -> void
appeal_ban(p_appeal_message text, p_user_id uuid) -> void
clone_task_version(p_task_id bigint, p_source_version_id bigint, p_new_title text DEFAULT NULL::text) -> public.task_versions
contains_banned_word(p_content text) -> boolean
count_search_profiles(search_query text) -> bigint
count_search_videos(search_query text) -> bigint
create_conversation(p_type text, p_receiver_id uuid, p_title text) -> bigint
create_task_draft_version(p_task_id bigint, p_title text, p_ui jsonb DEFAULT '{}'::jsonb, p_logic jsonb DEFAULT '{"pass": {"min_score": 0}, "rules": []}'::jsonb) -> public.task_versions
delete_message(p_message_id bigint) -> void
edit_message(p_message_id bigint, p_new_content text) -> public.messages
evaluate_task_submission(p_task_id bigint, p_version_id bigint, p_answer_data jsonb) -> jsonb
get_comments_with_like(p_video_id bigint, p_current_user uuid, p_parent_id bigint, p_limit integer, p_offset integer) -> TABLE
get_conversation_bot(p_conversation_id bigint) -> uuid
get_filtered_video_tags(p_tag_name text, p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) -> SETOF public.video_tags
get_followers_count(user_id uuid) -> integer
get_following_count(user_id uuid) -> integer
get_message_versions(p_message_id bigint) -> SETOF public.message_versions
get_my_jwt_sub() -> text
get_new_videos(p_user_id uuid DEFAULT NULL::uuid, p_cursor timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 20, p_only_unseen boolean DEFAULT false) -> SETOF public.videos
get_task_ui_schema_v1() -> jsonb
get_trending_candidates(p_user_id uuid DEFAULT NULL::uuid, p_cursor timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 60, p_days_back integer DEFAULT 40, p_only_unseen boolean DEFAULT false) -> SETOF public.videos
get_trending_candidates(p_days_back integer, p_cursor timestamp with time zone, p_only_unseen boolean, p_user_id uuid, p_use_youtube boolean, p_limit integer) -> SETOF public.videos
get_videos_by_tag(p_tag_name text, p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0, p_only_unseen boolean DEFAULT false) -> SETOF public.videos
increment_video_metric(p_video_id bigint, p_column text, p_delta integer) -> void
is_conversation_member(p_conversation_id bigint) -> boolean
is_conversation_member(p_conversation_id bigint, p_user_id uuid) -> boolean
is_current_user_admin() -> boolean
is_pro(p_user_id uuid) -> boolean
moderate_message() -> trigger
post_comment(p_author_id uuid, p_video_id bigint, p_content text, p_parent_id bigint) -> integer
publish_task_version(p_task_id bigint, p_version_id bigint, p_make_current boolean DEFAULT true) -> public.task_versions
quiz_eval_condition(p_cond jsonb, p_answers jsonb, p_vars jsonb, p_ctx jsonb DEFAULT '{}'::jsonb) -> boolean
quiz_logic_is_valid(p_logic jsonb) -> boolean
quiz_ref_value(p_ref jsonb, p_answers jsonb, p_vars jsonb, p_ctx jsonb DEFAULT '{}'::jsonb) -> jsonb
quiz_to_numeric(p_val jsonb) -> numeric
refresh_conversation_last_message(p_conversation_id bigint) -> void
request_pro_tier(key text) -> boolean
request_streak_update() -> integer
search_profiles(search_query text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) -> SETOF public.profiles
search_videos(search_query text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) -> SETOF public.videos
search_videos_with_author(search_query text, p_limit integer, p_offset integer) -> TABLE
search_videos_with_author(search_query text, p_limit integer, p_offset integer, p_show_youtube boolean) -> TABLE
search_videos_with_profiles(search_query text, p_limit integer, p_offset integer) -> TABLE
send_message(p_conversation_id bigint, p_content text) -> public.messages
send_message(p_conversation_id bigint, p_content text, p_reply_to_message_id bigint) -> json
solve_task(p_task_id bigint, p_answer_data text) -> boolean
solve_task(p_answer_data jsonb, p_task_id bigint) -> boolean
solve_task_v2(p_task_id bigint, p_answer_data jsonb, p_version_id bigint DEFAULT NULL::bigint) -> jsonb
sync_quest_connections_latest() -> trigger
sync_quests_latest() -> trigger
toggle_dislike(p_video_id bigint) -> text
toggle_dislike(p_user_id uuid, p_video_id bigint) -> text
toggle_follow(p_other_id uuid) -> text
toggle_like(p_video_id bigint) -> text
toggle_like(p_user_id uuid, p_video_id bigint) -> text
toggle_like_comment(p_comment_id integer) -> boolean
toggle_like_old(p_user_id text, p_video_id bigint) -> text
toggle_theme_like(p_theme_id uuid) -> boolean
track_message_versions() -> trigger
trg_inc_profile_video_count() -> trigger
unseen_video_tags(p_user_id uuid) -> SETOF public.video_tags
```