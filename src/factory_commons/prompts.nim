## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "factory-commons-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias, others: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", one of three cogs working a single shared factory. The other two are " & others & ". Nobody is on a team."
  of pvPlain: "You play " & alias & " in one shared factory with two other cogs, " & others & ". There are three cogs and no teams."
  of pvNumbered: "1. Your cog: " & alias & ". 2. Other cogs: " & others & ". 3. Workplace: one shared factory for all three. 4. Teams: none."
  of pvQuestions: "Who are you? " & alias & ". Who else works here? " & others & ". Where? One factory shared by three cogs. Are there teams? No."
  of pvReordered: "One factory is shared by three cogs, with no teams. The others are " & others & "; you are " & alias & "."
  of pvHeldoutBriefing: "Work as " & alias & " alongside " & others & " in their single shared factory. You are three cogs, each without a team."
  of pvHeldoutReference: "Factory: one, shared. Workers: three cogs. You: " & alias & ". Others: " & others & ". Team membership: none."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
