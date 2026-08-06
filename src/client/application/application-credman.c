/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/*
 * Windows Credential Manager access for SecretMediator.
 *
 * Only built on Windows, where there is no Secret Service to talk to.
 * See credman-mediator.vala, which declares these functions.
 *
 * Passwords are stored as generic credentials, which are protected by
 * the user's logon credentials and readable only by this user account.
 * The blob is the password's UTF-8 bytes, with no trailing NUL, which is
 * what CredUIParseUserName and the rest of the Windows tooling expects.
 */

#include <glib.h>
#include <gio/gio.h>

#ifdef G_OS_WIN32

#include <windows.h>
#include <wincred.h>

/*
 * Reports a failed credential call.
 *
 * ERROR_NO_SUCH_LOGON_SESSION gets its own message: the credential store
 * belongs to an interactive logon session, so every call fails this way
 * when the process was started from a network logon such as an SSH
 * session or a service, which is worth saying plainly rather than
 * reporting a bare error number.
 */
static void
set_credman_error (GError **error,
                   const gchar *call,
                   const gchar *target,
                   DWORD code)
{
  if (code == ERROR_NO_SUCH_LOGON_SESSION)
    g_set_error (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                 "The Windows credential store is not available to this "
                 "session; it requires an interactive logon (%s for %s)",
                 call, target);
  else
    g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                 "%s failed for %s: error %lu",
                 call, target, (unsigned long) code);
}

/* Stores a password, replacing any existing one for this target. */
gboolean
convey_credman_store (const gchar *target,
                      const gchar *user,
                      const gchar *password,
                      GError **error)
{
  wchar_t *w_target = (wchar_t *) g_utf8_to_utf16 (target, -1, NULL, NULL, error);
  if (w_target == NULL)
    return FALSE;

  wchar_t *w_user = (wchar_t *) g_utf8_to_utf16 (user, -1, NULL, NULL, error);
  if (w_user == NULL)
    {
      g_free (w_target);
      return FALSE;
    }

  CREDENTIALW cred;
  memset (&cred, 0, sizeof (cred));
  cred.Type = CRED_TYPE_GENERIC;
  cred.TargetName = w_target;
  cred.UserName = w_user;
  cred.CredentialBlob = (LPBYTE) password;
  cred.CredentialBlobSize = (DWORD) strlen (password);
  cred.Persist = CRED_PERSIST_LOCAL_MACHINE;

  gboolean ok = CredWriteW (&cred, 0);
  if (!ok)
    set_credman_error (error, "CredWriteW", target, GetLastError ());

  g_free (w_user);
  g_free (w_target);
  return ok;
}

/*
 * Returns the password stored for the target, or NULL if there is none.
 *
 * A missing credential is not an error: it is reported as NULL with no
 * error set, matching what the caller expects of a lookup.
 */
gchar *
convey_credman_lookup (const gchar *target,
                       GError **error)
{
  wchar_t *w_target = (wchar_t *) g_utf8_to_utf16 (target, -1, NULL, NULL, error);
  if (w_target == NULL)
    return NULL;

  PCREDENTIALW cred = NULL;
  gchar *password = NULL;

  if (CredReadW (w_target, CRED_TYPE_GENERIC, 0, &cred))
    {
      password = g_strndup ((const gchar *) cred->CredentialBlob,
                            cred->CredentialBlobSize);
      CredFree (cred);
    }
  else
    {
      DWORD err = GetLastError ();
      if (err != ERROR_NOT_FOUND)
        set_credman_error (error, "CredReadW", target, err);
    }

  g_free (w_target);
  return password;
}

/* Removes the password stored for the target, if any. */
gboolean
convey_credman_clear (const gchar *target,
                      GError **error)
{
  wchar_t *w_target = (wchar_t *) g_utf8_to_utf16 (target, -1, NULL, NULL, error);
  if (w_target == NULL)
    return FALSE;

  gboolean ok = CredDeleteW (w_target, CRED_TYPE_GENERIC, 0);
  if (!ok)
    {
      DWORD err = GetLastError ();
      if (err == ERROR_NOT_FOUND)
        {
          /* Nothing stored is not a failure to remove it. */
          ok = TRUE;
        }
      else
        {
          set_credman_error (error, "CredDeleteW", target, err);
        }
    }

  g_free (w_target);
  return ok;
}

#endif /* G_OS_WIN32 */
