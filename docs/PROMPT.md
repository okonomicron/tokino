# Tokino (ときの) — AI-Powered Personal Content Strategist

## Your Role

You are my **co-founder-level product strategist, senior iOS engineer, AI architect, and technical lead**.

Your assignment is to design and build **Tokino (ときの)**, a native iPhone application that transforms a user's existing photo library into a continuous, AI-driven social media content strategy.

I want you to take ownership of the project from concept through implementation, testing and eventual App Store submission.

Think critically about the product, challenge architectural decisions when justified, and recommend simpler or more effective solutions when appropriate.

Do not simply produce a specification. I want you to **implement the application progressively**, maintaining a working codebase in GitHub.

When capabilities are uncertain, verify them against current official documentation rather than making assumptions.

---

# 1. Product Vision

**App Name:** Tokino (ときの)

**Product Concept:**

An AI-powered personal content strategist that transforms a user's photo library into engaging social media content, based on natural-language instructions.

**Core proposition:**

> Your memories. Your stories. Your voice. Automatically.

Users should not need to manually search thousands of photographs, select images, write captions, edit videos or plan their publishing calendars.

Instead, they tell Tokino what they want to achieve.

Tokino intelligently discovers relevant photographs, reconstructs experiences using photo metadata, creates a coherent content strategy, generates platform-specific content, and manages the approval and publishing workflow.

The application must be designed for general consumers rather than a single niche.

## Initial Real-World Use Case

My personal use case will serve as the first end-to-end acceptance test.

I travel frequently throughout Japan and photograph kaisendon (海鮮丼), Japanese seafood rice bowls.

I want to create a social media presence around my experiences eating kaisendon across Japan.

Example prompt:

"Find all my photographs of kaisendon taken in Japan over the years. Identify the restaurants and locations whenever possible. Create an ongoing content strategy focused on regional seafood, restaurant discoveries, ingredients and memorable dining experiences. Generate engaging English Instagram posts and Chinese Xiaohongshu posts. Use an informative, personal, knowledgeable but unpretentious tone. Prepare a mixture of photo carousels and short videos. Publish three times weekly after my approval."

Tokino should interpret this as a content strategy, not simply an image-search request.

It might propose content pillars such as:

- Restaurant discoveries and reviews.
- Regional Japanese seafood specialities.
- Comparisons of different kaisendon.
- Seafood ingredient education.
- Travel memories.
- Recommended restaurants.
- Fishing ports and local food culture.

These must be grounded in the user's actual photos, experiences and verified information.

However, **nothing in the implementation should be hardcoded for kaisendon, Japanese travel or food content**.

A different user might create a strategy for pets, home cooking, fashion, parenting, hiking, gardening, architecture or fitness.

Users must be able to create multiple independent strategies.

---

# 2. Primary Product Requirements

## 2.1 Native iPhone Application

Develop a genuine native iOS application using Swift and SwiftUI.

Requirements:

- Modern, polished iOS interface.
- Excellent performance on recent iPhone devices.
- Support current stable iOS releases.
- Native Apple Photos integration.
- Background photo processing where supported.
- Push notifications.
- Secure account authentication.
- Native media preview.
- Accessibility and Dynamic Type support.
- Clear privacy controls.

Prefer native Apple frameworks rather than unnecessary third-party dependencies.

The product must not merely be a web application wrapped in a WebView.

## 2.2 Photo Library Integration

Tokino needs to discover and analyse photographs in the user's existing iPhone photo library.

### Initial Scan

On first use:

1. Request appropriate photo-library access.
2. Explain clearly why access is needed.
3. Enumerate accessible photo assets.
4. Extract available metadata, including:
   - Photo identifier.
   - Creation timestamp.
   - GPS coordinates.
   - Media type.
   - Dimensions.
   - Album associations where accessible.
   - Relevant image metadata.
5. Generate or retrieve efficiently sized thumbnails.
6. Analyse and index photographs.
7. Display scan progress.
8. Allow pause, resume and cancellation.
9. Recover safely from interrupted processing.

Do not unnecessarily download all original photographs from iCloud or upload all full-resolution images to the backend.

Use thumbnails or appropriately sized derivatives for analysis.

### Automatic Incremental Scanning

After the initial scan, Tokino should automatically detect and process newly added or modified photographs as far as iOS permits.

Investigate Apple's current PhotoKit change observation, background processing APIs and any supported background photo-library upload extensions.

Important requirements:

- Avoid rescanning the entire library.
- Support incremental updates.
- Detect deletions where permissions allow.
- Avoid duplicate indexing.
- Persist checkpoints.
- Handle iCloud-only assets.
- Respect battery, network and storage constraints.
- Support Wi-Fi-only processing.
- Allow users to pause automated scanning.

Do not claim guaranteed immediate background processing if iOS does not permit it.

Design a reliable fallback when the user next opens the application.

### Photo Privacy

Privacy must be an architectural priority.

Prefer keeping photo originals on the device until needed.

Only upload images or derivatives required for AI processing or publishing, with clear user authorisation.

Provide options to exclude photographs, albums or categories.

Consider a privacy-preserving architecture where image embeddings are generated locally, with cloud-based vision analysis used selectively.

Investigate feasibility and performance before selecting the approach.

---

# 3. AI Photo Intelligence

The system should create a reusable semantic index of the user's photographs.

Capabilities:

- Identify objects, food, animals, landscapes, activities and scenes.
- Search photographs using natural language.
- Group visually similar photographs.
- Detect near-duplicates.
- Recognise sequences of photographs from the same event.
- Assess photographic quality.
- Recommend images suitable for social media.
- Distinguish between relevant and irrelevant images.
- Extract useful context from menus, signs and storefront photographs using OCR where appropriate.

Possible technologies include:

- Apple Vision / Core ML.
- CLIP or SigLIP embeddings.
- Multimodal large language models.
- PostgreSQL with pgvector.
- Selective cloud-based image analysis.

Evaluate different implementations for accuracy, battery usage, operating cost, privacy and scalability.

The system should **index photographs once and reuse that index across multiple content strategies**.

Do not run an expensive full-library analysis every time a user creates a new strategy.

---

# 4. Experience Reconstruction and Location Intelligence

A major product differentiator is reconstructing real-world experiences from photograph collections.

For example, several photographs taken at a restaurant might include:

- The food.
- Restaurant exterior.
- Menu.
- Dining environment.
- Nearby landmarks.
- A receipt.
- A sign displaying the restaurant name.

Tokino should recognise that these photographs likely belong to the same experience.

## Grouping Logic

Use available contextual signals:

- GPS proximity.
- Timestamp proximity.
- Visual similarity.
- Image sequence.
- Recognised signs.
- Nearby landmarks.
- Existing photo album context.

Create a reusable `Experience` concept.

One experience can contain multiple photo assets and potentially generate multiple forms of content.

## Google Maps / Places Integration

When photographs include location metadata:

1. Extract coordinates and timestamps.
2. Search for nearby relevant places using the current Google Maps Platform APIs.
3. Consider the date of the photographs.
4. Identify likely restaurants, attractions, landmarks or businesses.
5. Cross-check the candidate against image content and other photographs.
6. Generate confidence estimates.
7. Let the user confirm or correct uncertain matches.

For example, a photograph taken at a Japanese seafood restaurant should ideally be associated with its actual Google Maps place listing.

Store appropriate place identifiers and permitted metadata in compliance with Google's licensing, caching and attribution requirements.

Be aware that current Google Maps listings may not reflect businesses that existed many years ago.

Never assume the nearest restaurant is necessarily the correct restaurant.

## Location Enrichment

Where supported, generated posts may include:

- Restaurant or venue name.
- City and prefecture.
- Country.
- Google Maps link.
- Date of visit.
- Relevant contextual information.

For supported social platforms, investigate whether the official publishing APIs permit assigning native location tags.

If not, include appropriately formatted location information in captions.

Clearly distinguish verified facts from inferred information.

---

# 5. Prompt-Driven Content Strategies

This is the central product feature.

Users create content strategies by describing their goals in natural language.

Example:

"Create an Instagram account featuring my hiking adventures, using my best landscape photographs. Post twice weekly with short educational captions and occasional Reels."

Tokino should transform that instruction into a structured and editable content strategy.

## Strategy Configuration

Each strategy should support:

- Strategy name.
- Original user prompt.
- Content objectives.
- Target audience.
- Content pillars.
- Relevant photograph selection criteria.
- Preferred social media platforms.
- Publishing frequency.
- Preferred posting times.
- Language preferences.
- Tone of voice.
- Personality.
- Hashtag preferences.
- Image/video preferences.
- Approval requirements.
- Automatic publishing settings.
- Excluded content.
- Privacy restrictions.

The AI should recommend an appropriate configuration but allow the user to modify it.

## Multiple Strategies

A user may have several strategies:

- Japan Kaisendon.
- Travel Photography.
- Home Cooking.
- Hiking Adventures.

Each strategy should have independent editorial calendars, drafts and publishing rules.

The same photograph may be relevant to multiple strategies, but users should be able to prevent repetitive posts.

## Strategy Evolution

The AI should periodically evaluate:

- Newly indexed photographs.
- Available content opportunities.
- Previously published posts.
- Content diversity.
- User feedback.
- Platform performance where analytics access is available.

It should recommend adjustments to the content strategy.

The system should avoid generating repetitive or low-quality posts merely to meet a publishing target.

---

# 6. Tone, Voice and Personality

Users must be able to define their own content identity.

Support both natural-language instructions and configurable profiles.

Example:

"Write as an experienced Japan traveller who enjoys local seafood and regional food culture. Be knowledgeable, conversational and informative. Avoid exaggerated praise, clickbait, excessive emojis and influencer-style language."

Each profile may specify:

- Formal versus casual.
- Educational versus entertaining.
- Concise versus descriptive.
- Humorous versus serious.
- Personal versus editorial.
- Preferred vocabulary.
- Emoji usage.
- Hashtag style.
- Languages.
- Words and expressions to avoid.

Users should be able to maintain different voices for different strategies.

For multilingual content, adapt naturally to the audience rather than translating word-for-word.

For example:

- Instagram: English.
- Xiaohongshu: Simplified Chinese.

## Learning From Feedback

When users edit or reject generated posts, Tokino should learn their preferences within the limits of explicitly authorised data use.

Consider storing approved examples and style preferences.

Do not silently train shared models on private user content.

---

# 7. AI Content Generation

Tokino should generate complete social media posts.

## Photo Posts

Capabilities:

- Identify suitable photographs.
- Rank by visual quality and relevance.
- Select a compelling cover photograph.
- Arrange images into a coherent sequence.
- Crop and resize for platform requirements.
- Generate optional title overlays.
- Create platform-specific captions.
- Generate hashtags.
- Add relevant location information.

Avoid unnecessary alterations to original photographs.

## Carousel Posts

Support multi-image storytelling.

For example:

"Five memorable seafood bowls from northern Japan."

The system should intelligently select and arrange photographs, avoid duplicates and generate an appropriate caption.

## Video / Reels

Generate short videos from existing photographs and video clips.

Capabilities:

- Animated photo transitions.
- Ken Burns-style pan and zoom.
- Text overlays.
- Subtitles.
- Simple titles.
- Platform-specific aspect ratios.
- Optional voice narration.
- Background music where legally licensed.
- Export to appropriate video formats.

Investigate using FFmpeg or another suitable rendering engine in the backend.

Start with dependable, deterministic video rendering rather than expensive generative-video services.

Later, optional AI video generation may be introduced if it adds genuine value.

## Platform-Specific Optimisation

Do not simply publish identical content to all platforms.

The content agent should consider:

- Platform conventions.
- Caption length.
- Hashtag practices.
- Carousel limits.
- Video duration.
- Aspect ratio.
- Audience language.
- Content format.
- Publishing restrictions.

Research current official specifications and keep the adapters maintainable as these change.

---

# 8. Social Media Integration

The application should support multiple social media platforms through independent adapters.

Initial priorities:

1. Instagram.
2. Xiaohongshu (小红书 / XHS).

Future candidates:

- TikTok.
- Facebook.
- YouTube Shorts.
- Other relevant platforms.

## Account Connection

Use official OAuth and authentication mechanisms wherever available.

Never request or store users' social media passwords.

Store tokens securely.

Support token refresh, disconnection and permission revocation.

## Instagram

Investigate Meta's current Instagram Platform APIs.

Support, where authorised:

- Account connection.
- Image publishing.
- Carousel publishing.
- Video/Reels publishing.
- Scheduled publishing through our backend.
- Publication status.
- Analytics where available.

Identify account-type requirements and App Review permissions.

## Xiaohongshu

Investigate official XHS Open Platform capabilities and current publishing-access restrictions.

Do not assume general public API access for automated posting.

Implement a supported assisted-publication workflow if full API publishing is unavailable.

This may include:

- Preparing the complete post.
- Exporting images/video.
- Copying the caption.
- Opening the appropriate app.
- Notifying users when publishing is due.

Avoid fragile or unauthorised automation that risks account restrictions.

Design the adapter so official publishing can be added later if access becomes available.

---

# 9. Review, Approval and Publishing

Every generated post should have a lifecycle.

Suggested states:

`idea → draft → review → approved → scheduled → publishing → published`

Also support:

- Rejected.
- Needs revision.
- Failed.
- Cancelled.

## Draft Review

Users should be able to:

- Preview the post.
- Edit the caption.
- Reorder photographs.
- Remove or replace images.
- Change platforms.
- Regenerate selected components.
- Confirm location information.
- Approve or reject.
- Schedule publication.

## Scheduling

Support:

- Immediate publishing.
- User-selected future dates.
- Recurring publishing schedules.
- AI-recommended publishing times.
- Editorial calendars.
- Time-zone awareness.
- Platform-specific queues.
- Retries for temporary failures.

**Backdating is not required.**

Historical photographs may be published today, with their original visit dates mentioned in captions where appropriate.

Scheduled publication must run on the backend, independently of the iPhone app being open.

## Automation Levels

Support three modes:

**Manual**

AI generates suggestions, but users explicitly approve and schedule posts.

**Semi-automatic**

AI generates and schedules drafts, while users approve them before publication.

**Fully automatic**

AI generates, schedules and publishes without per-post approval, but only where the user has explicitly enabled this capability and the platform officially supports it.

Include safeguards against accidental, duplicated, inappropriate or excessive publishing.

Default to approval-required mode.

---

# 10. Technical Architecture

I am an experienced software developer familiar with Python, JavaScript, Node.js, Next.js, PostgreSQL, Supabase, AWS, Docker, GitHub, Vercel and DevOps.

I prefer practical, maintainable technologies with minimal unnecessary complexity.

Evaluate and propose the best architecture rather than blindly adopting this suggested stack.

## iOS Frontend

Preferred:

- Swift.
- SwiftUI.
- PhotoKit.
- Vision / Core ML where appropriate.
- Swift concurrency.
- Native Apple authentication and keychain APIs.

## Backend

Preferred candidates:

- Python / FastAPI.
- Supabase PostgreSQL.
- pgvector.
- Supabase Auth.
- AWS S3 or compatible object storage.
- Background job workers.
- Durable scheduling and queueing.
- AI model APIs.
- Google Maps Platform APIs.

Use Vercel where appropriate, but do not force long-running AI processing or video-rendering tasks into unsuitable serverless environments.

## Deployment

Prefer managed cloud services when they reduce operational complexity.

Do not create unnecessary infrastructure or recurring costs.

The architecture should support future multi-user commercial deployment, but the initial MVP may be operated at small scale.

## Security

Design for:

- Secure token storage.
- Encryption in transit and at rest.
- Least-privilege permissions.
- User-level data isolation.
- Secure media access.
- Private object storage.
- Signed URLs.
- API rate limiting.
- Webhook verification.
- Secure background workers.
- Account deletion.
- Data export.
- Revocation of photo and social account access.

Do not expose API keys in the iOS client.

## Data Model

Propose a robust schema including entities such as:

- User.
- Device.
- PhotoAsset.
- PhotoEmbedding.
- Experience.
- PlaceMatch.
- ContentStrategy.
- VoiceProfile.
- ContentIdea.
- ContentDraft.
- MediaAsset.
- SocialAccount.
- Publication.
- PublishingSchedule.
- Approval.
- ProcessingJob.

Include appropriate foreign keys, indexes, state transitions, ownership rules and row-level security.

---

# 11. Cloud-First Development — Critical Requirement

I want to use **Claude Cloud as much as possible**.

My MacBook should be used only when absolutely necessary.

For example:

- Running Xcode when required.
- iOS Simulator testing that cannot run in the cloud.
- Testing on a physical iPhone.
- Apple signing and provisioning when necessary.
- App Store submission where cloud alternatives are unsuitable.

Do not assume my Mac needs to be continuously connected or running.

## Preferred Workflow

1. Use Claude's available cloud coding environment for planning, repository work, code generation, refactoring and tests.
2. Maintain the source code in a GitHub repository.
3. Develop backend services and tests in the cloud.
4. Implement SwiftUI source files directly in the cloud repository.
5. Use cloud CI for linting and tests whenever feasible.
6. Investigate macOS CI providers such as GitHub Actions macOS runners or Xcode Cloud for iOS building, testing, signing and distribution.
7. Use TestFlight for beta testing.
8. Perform local Mac tasks only when required.
9. Return all source changes and documentation to GitHub.

**Important:** Cloud-based code generation is not the same as cloud-based iOS compilation.

Verify which Apple development tools are actually available in your execution environment.

If a task requires macOS or Xcode, determine whether a cloud-hosted macOS runner can handle it before requiring local execution.

Do not claim to have built or tested the iOS application unless the relevant build or test actually ran.

## Local Mac Interaction

When local actions are necessary, provide exact, concise commands and instructions.

Prefer a workflow where I can pull the latest GitHub repository, run the necessary tests or submission steps, and return to cloud development.

Avoid asking me to perform manual work that could reasonably be automated.

---

# 12. Product Design and User Experience

The application should feel like a polished consumer product rather than a technical dashboard.

Design principles:

- Minimalist.
- Elegant.
- Fast.
- Calm.
- Easy to understand.
- Strong visual emphasis on photographs.
- Native iOS design conventions.
- Limited configuration burden.

The name Tokino (ときの) should evoke moments, memories and the passage of time.

Avoid generic AI chatbot interfaces as the primary experience.

The user should interact naturally with the product.

## Main Screens

Propose and implement screens such as:

**Home / Discover**

AI-discovered stories and content opportunities.

**Strategies**

Create, view and manage prompt-driven content strategies.

**Photo Library**

Search and browse indexed photographs.

**Content Studio**

Preview and edit AI-generated posts.

**Drafts**

Posts awaiting approval or further editing.

**Calendar**

Scheduled and published content.

**Social Accounts**

Connect and manage publishing destinations.

**Settings**

Privacy, scanning preferences, AI preferences, subscription and account management.

## Onboarding

Design an excellent first-run experience:

1. Explain the product.
2. Create/sign in to an account.
3. Explain photo privacy and request access.
4. Start a resumable photo scan.
5. Invite the user to describe a content strategy.
6. Discover relevant photographs.
7. Generate an initial content proposal.
8. Produce a first draft.
9. Optionally connect social media.
10. Review and approve content.

The user should experience value before having to configure every setting.

---

# 13. Commercial and Business Strategy

Although I will initially use Tokino personally, design it with the possibility of launching commercially.

Investigate:

- Target customer segments.
- Differentiation from conventional social media scheduling tools.
- Competitor landscape.
- Pricing models.
- Free versus paid tiers.
- AI processing costs.
- Cloud storage costs.
- Photo indexing costs.
- Video generation costs.
- Social API limitations.
- Customer acquisition.
- User retention.

Potential pricing structure:

**Free**

Limited photo indexing, one strategy, limited drafts, manual publishing.

**Pro**

Larger library, multiple strategies, advanced content generation, scheduling and more platform integrations.

**Premium**

Advanced AI strategy management, video generation, analytics and higher processing limits.

Treat these as hypotheses, not final pricing decisions.

Provide a practical unit-economics model showing costs for representative users with 5,000, 20,000 and 100,000 photographs.

Consider whether image analysis should be predominantly on-device to avoid prohibitive cloud inference costs.

Consider privacy and App Store subscription requirements.

Avoid overengineering commercial infrastructure before product-market fit has been demonstrated.

---

# 14. Quality, Testing and Reliability

The application must be built to production engineering standards.

Implement:

- Unit tests.
- Integration tests.
- API contract tests.
- Background processing tests.
- Database migration tests.
- Publishing state-machine tests.
- Duplicate publication prevention.
- Failure recovery.
- Secure authentication tests.
- Photo permission edge cases.
- iCloud asset availability handling.
- Cancellation and resumability.
- Observability and structured logs.

For publishing, use idempotent jobs and explicit state transitions.

Prevent duplicate posts if a worker retries after a timeout.

Treat social API responses carefully, particularly when the external publication may have succeeded but the confirmation response was lost.

Implement sensible handling of rate limits and expired credentials.

---

# 15. Development Methodology

Work in manageable, testable milestones.

Do not attempt to implement the entire product in a single uncontrolled coding session.

Maintain a clear GitHub history with focused commits.

Create project documentation covering:

- Product requirements.
- Architecture.
- Data model.
- API specification.
- Development environment.
- Cloud deployment.
- iOS build and testing.
- Security model.
- Known constraints.
- Roadmap.
- Decision log.

For every milestone:

1. State the objective.
2. Implement the functionality.
3. Run available tests.
4. Report what passed and failed.
5. Document any constraints.
6. Commit changes.
7. Identify the next milestone.

Do not silently substitute mock integrations for working implementations.

Mocks are acceptable during development but must be clearly identified.

---

# 16. Recommended MVP Scope

Prioritise a functional vertical slice rather than implementing every feature superficially.

## Milestone 1 — Foundation

- GitHub repository.
- Project structure.
- SwiftUI app skeleton.
- Cloud backend.
- Supabase database.
- Authentication.
- CI setup.
- Initial architecture documentation.

## Milestone 2 — Photo Discovery

- PhotoKit integration.
- Initial library scan.
- Resumable processing.
- Incremental scanning.
- Image metadata extraction.
- Semantic indexing.
- Natural-language image search.

## Milestone 3 — Experience and Location Intelligence

- Group related photographs.
- Extract and use GPS metadata.
- Google Maps/Places integration.
- Restaurant/place matching.
- User confirmation interface.

## Milestone 4 — Content Strategy

- Natural-language strategy creation.
- Structured strategy representation.
- Custom voice profiles.
- Content pillar generation.
- Content idea suggestions.

## Milestone 5 — Content Generation

- Photo selection.
- Carousel generation.
- English and Chinese captions.
- Hashtags.
- Draft preview.
- Editing and approval workflow.

## Milestone 6 — Publishing

- Instagram account integration.
- Official Instagram publishing.
- Backend scheduler.
- Publication status.
- XHS assisted publishing workflow.

## Milestone 7 — Video and Advanced Automation

- Short-form video generation.
- Platform-specific templates.
- Editorial calendar automation.
- Performance analytics.
- Optional fully automatic publishing.

Each milestone must leave the repository in a usable state.

---

# 17. Decisions and Constraints

Please respect the following:

1. The name is **Tokino (ときの)**.
2. The application is native iOS, not a PWA.
3. The application must support generic user-defined content strategies.
4. Japan kaisendon is the initial acceptance use case only.
5. The original iPhone photo library must remain untouched.
6. Privacy and user control are essential.
7. Instagram and XHS are the initial target platforms.
8. Future platforms should be added through modular adapters.
9. Scheduled publishing is required.
10. Backdating is not required.
11. AI-generated content must not fabricate personal experiences.
12. Location intelligence is a significant product feature.
13. Photo and video formats should both be supported eventually.
14. Cloud-based development is strongly preferred.
15. Mac-based development should be minimised.
16. GitHub is the source of truth.
17. Use real tests and report actual execution results.
18. Optimise for a reliable MVP, not maximum feature count.
19. Do not commit secrets, credentials or signing certificates into the repository.
20. Do not purchase cloud resources, subscribe to paid services or deploy potentially chargeable infrastructure without my approval.

---

# 18. Your First Assignment

Before implementation, carry out a focused technical and product feasibility assessment using current official documentation.

Specifically investigate:

1. **Apple PhotoKit:** How can an iPhone application perform an initial full-library scan and subsequently index new photographs automatically? What are the actual background execution limitations on current iOS?

2. **Cloud development:** Which parts of native SwiftUI development, compilation, testing, signing and TestFlight distribution can be performed through Claude Cloud and cloud-hosted macOS CI? What genuinely requires my Mac?

3. **Image intelligence:** What is the most cost-effective combination of on-device image embeddings, cloud AI and vector search?

4. **Google Maps:** What is the recommended and compliant method for matching photo GPS coordinates to historical restaurants and other points of interest?

5. **Instagram:** What are the current official requirements for authentication, media publishing, carousel/Reels posting and scheduling?

6. **Xiaohongshu:** What official publishing capabilities are currently available? What is the most practical compliant fallback?

7. **Video generation:** What architecture would support high-quality videos assembled from photographs without excessive rendering costs?

8. **Economics:** What is the approximate cost of indexing 20,000 photographs and maintaining three posts per week for one user?

9. **Market validation:** What existing apps offer similar capabilities, and how can Tokino differentiate itself?

10. **MVP:** What is the smallest product that can convincingly validate the idea using my personal kaisendon photographs?

## Initial Deliverables

Produce:

- A concise product requirements document.
- Technical feasibility findings, with official documentation links.
- Proposed system architecture.
- Proposed database model.
- Cloud-first development workflow.
- MVP scope.
- Milestone roadmap.
- Infrastructure and operating cost estimates.
- Key risks and mitigations.
- A recommended implementation plan.

Clearly separate:

- Verified platform capabilities.
- Engineering assumptions.
- Features requiring third-party approval.
- Features requiring further experimentation.

## Then Begin Implementation

Once you have presented the key architectural trade-offs and identified any decisions that genuinely require my approval, proceed with the first implementation milestone.

Use sensible defaults for minor engineering decisions rather than asking unnecessary questions.

If GitHub access and a usable cloud coding environment are available, start by establishing the project structure and implementing the foundation.

If an external account, credential, paid resource or Apple Developer entitlement is needed, explain exactly what is required and why.

**The objective is a working Tokino application, not merely a planning exercise.**