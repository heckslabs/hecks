// Prints a sign-in link for the editor, valid for 8 hours, signed with the demo's throwaway secret.
import { accountToken } from "../editor/node_modules/@hecks/client/dist/index.js";
const email = process.argv[2] ?? "isla@marlowfinch.example";
console.log(`${process.env.EDITOR_URL ?? "http://127.0.0.1:48420"}/editor/api/sso?token=${accountToken(process.env.AUTH_SECRET, email, 8 * 3600)}`);
