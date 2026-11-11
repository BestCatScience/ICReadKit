package com.bestcatscience.icreadkit;

/**
 * A card the kit can pretend to read, so a host app can build and test its screens on an emulator.
 * The certificate is synthetic: made up here, with no real person's data.
 */
public enum DemoCard {
    VALID("valid"),
    EXPIRED("expired"),
    OTHER_CARD("other-card"),
    CONNECTION_LOST("connection-lost");

    /** The same identifiers the iOS kit uses, so UI tests can share scenarios. */
    public final String id;

    DemoCard(String id) {
        this.id = id;
    }
}
