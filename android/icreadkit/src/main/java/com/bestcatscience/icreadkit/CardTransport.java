package com.bestcatscience.icreadkit;

/**
 * Moves command APDUs to a card and brings the responses back. IsoDep is one implementation; tests
 * and the demo card are others, so the reading logic never depends on a phone or a real card.
 */
interface CardTransport {
    ResponseApdu transmit(CommandApdu command) throws CardReadException;
}
