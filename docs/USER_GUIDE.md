# User guide

Codex Lens starts from a session, then connects its events, agents, calls, environments, resources, and file versions. You can explore in any order; opening a session does not resume it in Codex.

For the complete inventory of functions, settings and source-dependent limits, see the illustrated [Feature catalogue](FEATURES.md).

## Open a session

1. Choose **File → Open Session…** or press **Command-O**.
2. Select a session, paste its session or thread ID, or paste a link such as `codex://threads/11111111-1111-4111-8111-111111111111`.
3. Confirm the source directory in the picker. Choose **My Codex Sessions** if you are looking at a test or custom directory instead of your personal sessions.

Lens loads available history, including archived sessions, and follows newly persisted events. Its optional first-use introduction can be skipped and replayed from **Settings → Help**. An existing session remains visible while another one loads; a failed opening does not discard the current session.

If a session is missing, check its source directory and local availability first. A turn ID or tool-call ID is not a session ID. A session ID with an ambiguous local mapping requires the precise thread ID.

## Read activity

![Activity timeline and event list](images/activity.png)

Select an event to highlight it in the timeline and list. Double-click it or press Return to read its contents. The inspector links the event to its agent, environment, resources, and related actions. Opening a reader keeps an **Activity** return item beside the reading tabs. It restores the selection, filters, timeline framing and list position you left. Ordinary list clicks keep explicitly opened tabs intact.

**Back** and **Forward** also restore these positions. Closing the last reader returns to the originating collection. **Control-Tab** cycles between the collection and its readers, including when there is only one reader. Right-click a timeline event or a reading tab and choose **Open in a new window** to inspect it separately; the original window keeps its place. This command requires accessible session journals. Archived context remains readable in its current window when those journals are unavailable.

At a wide time scale, nearby events form groups. Click a group to zoom in; zoom out to see groups again. The event list keeps the individual records accessible. Use search, event-type filters, and a selected time range to narrow the view.

**Live** keeps a moving timeline above the reading area, so you can inspect a call or diff while keeping recent activity visible. Pausing or moving back in time pauses visual following, not collection. **Return to Live** publishes arrivals and returns to the current window. The display follows persisted logs, not a direct connection to another Codex process; events can appear with a delay.

Recorded compaction events and inter-agent communications appear when supported data exists. A sent message, a known receipt, and confirmed inclusion in a request are separate states. An opaque compaction is not replaced with an invented summary.

## Follow an action to its files

1. Open a call and inspect its arguments, result, and recorded source data.
2. Follow its related file or change into **Changes**.
3. Check the environment/worktree and the version labels before interpreting the diff.
4. Open **Origin and Justification** in the inspector to follow recorded links to the agent, mission, parent, and associated instructions.

![Diff and version references](images/diff.png)

The app distinguishes a requested patch, its recorded tool result, available historical content, and the current Git diff. A reported successful patch does not establish a complete historical file version. The current worktree diff is not automatically attributed to Codex.

**Before**, **After**, and **Compare** are available when their content can be read or verifiably reconstructed. When complete versions are unavailable, patch fragments retain local coordinates rather than pretending to be full files. The two unified-diff gutters refer to the before and after versions.

Use a file's context menu to reveal its current location in Finder or open it with another app. These actions refer to the **current** file; they do not change the historical content displayed in Lens. Editing in an external app is outside Lens's read-only inspection boundary.

## Explore environments and resources

**Environments** shows the directories used by the session and known descendants. Browse the accessible tree, not just modified files. The same relative path in two worktrees denotes two different files. A deleted worktree keeps its historical reference, while its current contents are unavailable.

**Resources** distinguishes supplied, referenced, recorded-read, modified, and produced content. A reference to an attachment does not guarantee its bytes remain available. Local text, code, images, and PDFs can be previewed; external URLs are not fetched automatically.

For a missing attachment, **Find File…** lets you search chosen local directories. A matching name is a candidate, not confirmation of the original content. The current recovery screen shows the candidate's observed hash but does not supply a recorded original hash for comparison. Opening a candidate labels it as a current local observation. Cloud placeholders are not downloaded by Lens; make them available explicitly in Finder before retrying.

## Ask questions in the sidebar chat

![Investigation chat with selected context](images/chat.png)

1. Open the chat with **Option-Command-C**. Lens checks the installed Codex and its connection without sending a question.
2. If needed, open **Settings → AI** to inspect or choose the executable. This adapter requires Codex **0.159.2** with a ChatGPT connection. Sign in using Codex itself if it is signed out.
3. Write a question. Optionally use **Add to Question**, the attachment menu, or an item's **Ask AI…** context action to include messages, calls, diffs, agents, or excerpts.
4. Review the attached context and version references, then send. Return sends; Shift-Return inserts a newline.
5. Continue in the same chat. Open a cited source to inspect the content attached to that response, or add it to a follow-up.

Context is frozen for each send. New activity in the observed session does not silently replace the versions used by an earlier response. A chat may be used without a selected object, but the model then has only the conversation and attached context; it does not receive the whole session automatically.

Lens owns a separate investigation thread and excludes it from observed production-agent activity. Its technical permission profile restricts tools and readable files, disables inherited hooks/connectors, and does not grant write access to observed repositories. A context menu prepares a question; it never sends automatically.

Sending transmits the question, attached context, and conversation to OpenAI through Codex. Authentication status, the model catalogue, and completion of a model request are separate checks. Catalogue availability does not guarantee model access. Cancellation or an error preserves the draft and does not trigger an automatic resend.

## Export a conversation or investigation

**File → Conversation and Guidance…** opens the main thread's user and assistant messages for a local JSON or Markdown export. Recorded lexical markers can help locate corrections or redirections, but are observations, not an authoritative interpretation of the user's intent. Missing and partial messages remain marked. This export does not include every tool record or every descendant conversation.

Investigation import/export preserves selected context and the chat archive in Lens's versioned format. It is distinct from a complete session backup. Imported paths are provenance references; importing an archive does not open or execute them. Review exported conversations before sharing them: redaction recognizes some secrets, not every possible sensitive detail.

## Adjust your workspace

Drag pane dividers to resize the sidebar, content, inspector, and chat. The **View** menu hides panels and adjusts the active pane; windows can be moved, resized, and used in full screen. Each window keeps its own navigation.

**Settings → General** controls language, appearance, reading fonts, zoom increments, and pinch behavior. Content surfaces remain stable while macOS 26 can use Liquid Glass for navigation controls. Reduced-motion and transparency preferences are respected.

| Action | Shortcut |
| --- | --- |
| Open session / new window | Command-O / Command-N |
| Find in active text / find in session | Command-F / Shift-Command-F |
| Back / Forward | Command-[ / Command-] |
| Show inspector / chat | Option-Command-I / Option-Command-C |
| Focus sidebar, content, inspector, chat | Option-Command-1 through Option-Command-4 |
| Resize active pane | Option-Command-Left / Option-Command-Right |
| Increase / decrease / reset zoom | Command-Plus / Command-Minus / Command-0 |
| Show Live / pause visual following | Option-Command-L / Shift-Command-L |
| Add selection to question | Shift-Command-E |
| Conversation export | Option-Command-E |
| Next / previous reading tab | Control-Tab / Shift-Control-Tab |

Commands apply to the active window and focused region. **Command-Plus/Minus** zooms the timeline when it has focus, or adjusts reading text in the relevant content view.

## Understand missing data

Open **Sources and limitations…** from the session menu when an event, result, attachment, or descendant is missing. Lens cannot recover events that were never persisted, deleted histories, inaccessible remote journals, or encrypted content merely by displaying them. Historical timestamps and collection times can differ. Temporal proximity alone does not establish causality, receipt, or application of an instruction.
