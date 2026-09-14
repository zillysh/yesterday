import { openai } from "@ai-sdk/openai";
import {
  convertToModelMessages,
  createUIMessageStream,
  createUIMessageStreamResponse,
  generateId,
  stepCountIs,
  streamText,
  tool,
  type UIMessage,
} from "ai";
import { z } from "zod";
import { catalogDigest } from "@/lib/catalog";
import { searchLive } from "@/lib/live";
import { localStylistReply, serializeProduct } from "@/lib/recommend";

export const maxDuration = 30;

const system = `You are Aisle, a visual shopping editor for one person's stores: H&M, Mango, Zara, American Eagle, Garage, and Aritzia.
Speak briefly, like notes on a moodboard. Dry, specific, no hype.
Always call searchStores with the shopper’s query (or a cousin query for "more like this") so we pin live pieces from those stores.
Hunt cousins by silhouette, color, and vibe across brands. Respect budgets ("under $40", "too exp").
Seed catalog (for when live search is empty):

${catalogDigest}

When they want something missing, say so and pull the closest visual cousins.`;

function lastUserText(messages: UIMessage[]) {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i];
    if (message.role !== "user") continue;
    return message.parts
      .filter((part): part is { type: "text"; text: string } => part.type === "text")
      .map((part) => part.text)
      .join(" ");
  }
  return "";
}

async function mockStream(prompt: string) {
  const clean = prompt.replace(/\n\[ref:[a-z0-9-]+\]/gi, "").trim();
  const { products } = await searchLive({
    query: clean || "cute new things from my stores",
    limit: 8,
  });
  const text = localStylistReply(clean, products);
  const callId = generateId();
  const textId = generateId();

  const stream = createUIMessageStream({
    execute({ writer }) {
      writer.write({ type: "text-start", id: textId });
      writer.write({ type: "text-delta", id: textId, delta: text });
      writer.write({ type: "text-end", id: textId });
      writer.write({
        type: "tool-input-available",
        toolCallId: callId,
        toolName: "searchStores",
        input: { query: clean },
      });
      writer.write({
        type: "tool-output-available",
        toolCallId: callId,
        output: { products: products.map(serializeProduct) },
      });
    },
  });

  return createUIMessageStreamResponse({ stream });
}

export async function POST(req: Request) {
  const { messages }: { messages: UIMessage[] } = await req.json();
  const prompt = lastUserText(messages);

  if (!process.env.OPENAI_API_KEY) {
    return mockStream(prompt || "cute new things from my stores");
  }

  const result = streamText({
    model: openai("gpt-4o-mini"),
    system,
    messages: await convertToModelMessages(messages),
    stopWhen: stepCountIs(4),
    tools: {
      searchStores: tool({
        description:
          "Search H&M, Mango, Zara, American Eagle, Garage, and Aritzia for live pieces that match the brief.",
        inputSchema: z.object({
          query: z.string().describe("Shopping query, including budget if any"),
        }),
        execute: async ({ query }) => {
          const { products } = await searchLive({ query, limit: 8 });
          return { products: products.map(serializeProduct) };
        },
      }),
    },
  });

  return result.toUIMessageStreamResponse();
}
