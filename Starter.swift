// The starter set a new SpinBreak user gets: generic, editable in Settings, no assumptions about kids, pets or faith.
// Your own AI replaces it with a list that fits your life (Settings › Your AI).
import Foundation

extension Engine {
    /// A rough home location until the user sets one: longitude from the time zone, a mid latitude.
    /// Good enough for sunrise/sunset to be within about half an hour.
    static func guessedLocation() -> (lat: Double, lon: Double) {
        let lon = Double(TimeZone.current.secondsFromGMT() - Int(TimeZone.current.daylightSavingTimeOffset())) / 3600 * 15
        return (40, max(-180, min(180, lon)))
    }

    static func starterCatalog() -> Catalog {
        let here = guessedLocation()
        return Catalog(
            latitude: here.lat, longitude: here.lon, horizon: nil,
            groups: [
                "ex": GroupRule(cap: 3, gap: 90),
                "vig": GroupRule(cap: 1),
                "screen": GroupRule(cap: 2),
                "caff": GroupRule(cap: 2, gap: 120),
                "clean": GroupRule(cap: 2, gap: 120),
            ],
            categories: [
                "outdoors": CategoryRule(target: 3, cap: 5),
                "movement-hard": CategoryRule(target: 1, cap: 1),
                "movement-light": CategoryRule(target: 1, cap: 3),
                "social": CategoryRule(target: 1, cap: 3),
                "learning": CategoryRule(target: 2, cap: 4),
                "creative": CategoryRule(target: 1, cap: 3),
                "home": CategoryRule(target: 2, cap: 4),
                "rest": CategoryRule(target: 1, cap: 3),
                "play": CategoryRule(target: 1, cap: 2),
                "nourish": CategoryRule(target: 2, cap: 4),
            ],
            activities: [
                // Outdoors
                Activity(id: "morning-light", emoji: "🌅", name: "Morning light walk", category: "outdoors",
                         how: "Get outside within a couple hours of sunrise. Look toward the bright sky, phone stays in your pocket.",
                         from: 5, to: 11, weight: 5, anchor: "sun", daylight: true),
                Activity(id: "walk", emoji: "🚶", name: "Walk around the block", category: "outdoors",
                         how: "Any direction, any pace. Notice three things you've never noticed before.",
                         maxPerDay: 2, minGap: 120, weight: 4, daylight: true),
                Activity(id: "lunch-walk", emoji: "🥪", name: "Post-lunch walk", category: "outdoors",
                         how: "An easy loop within 30 minutes of eating. It flattens the afternoon slump.",
                         from: 12, to: 15, weight: 3, soft: "12:30-14:00", daylight: true),
                Activity(id: "sit-outside", emoji: "🌳", name: "Sit outside, no phone", category: "outdoors",
                         how: "Porch, park bench, back step. Just sit and let your eyes look far away.",
                         weight: 2, daylight: true),
                Activity(id: "sunset", emoji: "🌇", name: "Catch the sunset", category: "outdoors",
                         how: "Find the western sky and watch it go. Bring someone if you can.",
                         from: 0, to: 24, weight: 2, soft: "sunset"),

                // Movement
                Activity(id: "workout", emoji: "🏋️", name: "Real workout", category: "movement-hard",
                         how: "Lift, run, ride, climb: whatever you actually do. 25 honest minutes.",
                         from: 6, to: 17, weight: 4, groups: ["ex", "vig"]),
                Activity(id: "stretch", emoji: "🧘", name: "Stretch and mobility", category: "movement-light",
                         how: "Hips, hamstrings, upper back, neck. Slow, breathing, no rushing.",
                         maxPerDay: 2, minGap: 120, weight: 3, groups: ["ex"]),
                Activity(id: "bodyweight", emoji: "💪", name: "Push-ups, squats, plank", category: "movement-light",
                         how: "Three easy rounds. Stop each set a couple reps before failure.",
                         weight: 2, groups: ["ex"], notFirst: true),

                // Social
                Activity(id: "call", emoji: "📞", name: "Call someone you love", category: "social",
                         how: "A real call, not a text. Ask them a question you've never asked.",
                         from: 9, to: 20.5, weight: 3),
                Activity(id: "thanks", emoji: "💌", name: "Three thank-you notes", category: "social",
                         how: "Short and specific: what they did and what it meant. Text, card or email.",
                         weight: 2, seated: true, weeklyMax: 2),
                Activity(id: "people-time", emoji: "🏡", name: "Time with your people", category: "social",
                         how: "Whoever's around: family, roommates, a neighbor. Be fully there.",
                         from: 15, to: 22, weight: 3),

                // Learning
                Activity(id: "read", emoji: "📖", name: "Read a real book", category: "learning",
                         how: "Paper or e-ink, somewhere comfortable. No phone within reach.",
                         maxPerDay: 2, minGap: 120, weight: 4, seated: true),
                Activity(id: "language", emoji: "🗣️", name: "Practice a language", category: "learning",
                         how: "Flashcards first, then out loud: shadow a clip or talk to yourself.",
                         weight: 3, seated: true),
                Activity(id: "learn-skill", emoji: "🧠", name: "Learn one thing deliberately", category: "learning",
                         how: "Pick one small skill and practice its hardest part. Write down what you learned.",
                         weight: 2, seated: true),

                // Creative
                Activity(id: "sketch", emoji: "✏️", name: "Sketch what's in front of you", category: "creative",
                         how: "Pen and paper, no erasing. A mug, your hand, the view. Draw what you see, not what you know.",
                         weight: 3, seated: true),
                Activity(id: "journal", emoji: "📝", name: "Write by hand", category: "creative",
                         how: "Journal, a letter, ideas. Keep the pen moving the whole time.",
                         weight: 2, seated: true),
                Activity(id: "music", emoji: "🎸", name: "Play or practice music", category: "creative",
                         how: "Pick up the instrument. Ten minutes of the hard part, then play for fun.",
                         weight: 2),

                // Home: rooms (the "clean" group) get surveyed early, then come up by how messy they were
                Activity(id: "clean-kitchen", emoji: "🍽️", name: "Kitchen reset", category: "home",
                         how: "Dishes, counters, sink, floor. Leave it ready for the next meal.",
                         weight: 3, groups: ["clean"]),
                Activity(id: "clean-living", emoji: "🛋️", name: "Living room", category: "home",
                         how: "Everything back where it lives, surfaces wiped, a quick vacuum.",
                         weight: 2, groups: ["clean"], weeklyMax: 3),
                Activity(id: "clean-bedroom", emoji: "🛏️", name: "Bedroom", category: "home",
                         how: "Clothes away, nightstand cleared, sheets changed if it's been a week.",
                         weight: 2, groups: ["clean"], weeklyMax: 3),
                Activity(id: "clean-bathroom", emoji: "🚿", name: "Bathroom", category: "home",
                         how: "Mirror, sink, toilet, floor. Restock what's running low.",
                         weight: 2, groups: ["clean"], weeklyMax: 2),
                Activity(id: "clean-entry", emoji: "🚪", name: "Entryway and drop zones", category: "home",
                         how: "Shoes, bags, mail, the pile by the door. Find everything a home.",
                         weight: 2, groups: ["clean"], weeklyMax: 2),
                Activity(id: "laundry", emoji: "🧺", name: "Laundry, one full load", category: "home",
                         how: "Wash, dry, fold and put away. The putting away is the part that counts.",
                         weight: 2, weeklyMax: 4),
                Activity(id: "fix-it", emoji: "🔧", name: "Fix one small broken thing", category: "home",
                         how: "The squeaky hinge, the dead bulb, the wobbly chair. Just one.",
                         weight: 2, weeklyMax: 2),
                Activity(id: "money", emoji: "💵", name: "Money check-in", category: "home",
                         how: "Look at last week's spending, pay anything due, move one dollar toward a goal.",
                         weight: 2, seated: true, weeklyMax: 1),

                // Rest
                Activity(id: "nap", emoji: "😴", name: "Power nap", category: "rest",
                         how: "Lie down, set a 20-minute alarm, eyes closed even if you don't sleep.",
                         from: 13, to: 16, weight: 2),
                Activity(id: "window", emoji: "🪟", name: "Do nothing by a window", category: "rest",
                         how: "No input at all. Let your mind wander wherever it wants.",
                         weight: 2, seated: true),

                // Play
                Activity(id: "hobby", emoji: "🧩", name: "Hobby time", category: "play",
                         how: "The thing you do just because you like it. No goal required.",
                         weight: 3),
                Activity(id: "game", emoji: "🎲", name: "Play a game with someone", category: "play",
                         how: "Cards, a board game, catch in the yard. Anything with another person.",
                         from: 12, to: 22, weight: 2),

                // Nourish
                Activity(id: "coffee", emoji: "☕", name: "Make coffee or tea, slowly", category: "nourish",
                         how: "Make it by hand and drink it away from the screen.",
                         from: 9.5, to: 14, weight: 3, groups: ["caff"]),
                Activity(id: "lunch", emoji: "🥗", name: "Make a real lunch", category: "nourish",
                         how: "Cook something with a vegetable in it and eat it sitting down, no screen.",
                         from: 11.5, to: 14, weight: 3, anchor: "12:00-13:00"),
                Activity(id: "snack", emoji: "🍎", name: "Water and a real snack", category: "nourish",
                         how: "A big glass of water and something that grew out of the ground.",
                         maxPerDay: 2, minGap: 180, weight: 2),
                Activity(id: "dinner-prep", emoji: "🥕", name: "Prep tonight's dinner", category: "nourish",
                         how: "Chop, marinate, start the slow part now so tonight is easy.",
                         from: 15, to: 18, weight: 2),
            ],
            checklist: [
                "💧 Big glass of water",
                "🪥 Teeth brushed",
                "☀️ Got outside light (or will at the first break)",
                "🍳 Breakfast eaten or planned",
                "🛏️ Bed made",
                "📵 Didn't start the day in my phone",
                "🎯 I know the one thing that matters today",
            ]
        )
    }
}
