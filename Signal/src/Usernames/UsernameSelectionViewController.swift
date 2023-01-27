//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import BonMot
import Foundation
import SignalMessaging

/// Provides UX allowing a user to select or delete a username for their
/// account.
///
/// Usernames consist of a user-chosen "nickname" and a programmatically-
/// generated numeric "discriminator", which are then concatenated.
class UsernameSelectionViewController: OWSTableViewController2 {

    /// A wrapper for injected dependencies.
    struct Context {
        let networkManager: NetworkManager
        let databaseStorage: SDSDatabaseStorage
        let profileManager: ProfileManagerProtocol
    }

    enum Constants {
        /// Minimum length for a nickname, in Unicode code points.
        static let minNicknameCodepointLength: UInt = 3

        /// Maximum length for a nickname, in Unicode code points.
        static let maxNicknameCodepointLength: UInt = 32

        /// Amount of time to wait after the username text field is edited
        /// before kicking off a reservation attempt.
        static let reservationDebounceTimeInternal: TimeInterval = 0.5

        /// Size of the header view's icon.
        static let headerViewIconSize: CGFloat = 64
    }

    /// A logger for username-selection-related events.
    private class UsernameLogger: PrefixedLogger {
        static let shared: UsernameLogger = .init()

        private init() {
            super.init(prefix: "[Username Selection]")
        }
    }

    private enum UsernameSelectionState: Equatable {
        /// The user's existing username is unchanged.
        case noChangesToExisting
        /// The user's existing username should be deleted.
        case shouldDelete
        /// The username is pending reservation. Stores an attempt ID, to
        /// disambiguate multiple potentially-overlapping reservation
        /// attempts.
        case reservationPending(attemptId: UUID)
        /// The username has been successfully reserved.
        case reservationSuccessful(reservation: API.SuccessfulReservation)
        /// The username was rejected by the server during reservation.
        case reservationRejected
        /// The reservation failed, for an unknown reason.
        case reservationFailed
        /// The username is too short.
        case tooShort
        /// The username is too long.
        case tooLong
        /// The username contains invalid characters.
        case invalidCharacters
    }

    typealias ParsedUsername = Usernames.ParsedUsername
    typealias API = Usernames.API

    // MARK: - Init

    /// Backing value for ``currentUsernameState``. Do not access directly!
    private var _currentUsernameState: UsernameSelectionState = .noChangesToExisting {
        didSet {
            AssertIsOnMainThread()

            guard
                oldValue != _currentUsernameState,
                isViewLoaded
            else {
                return
            }

            updateTableContents()
            updateNavigation()
        }
    }

    /// Represents the current state of username selection. Must only be
    /// accessed on the main thread.
    private var currentUsernameState: UsernameSelectionState {
        get {
            AssertIsOnMainThread()

            return _currentUsernameState
        }
        set {
            AssertIsOnMainThread()

            _currentUsernameState = newValue
        }
    }

    /// A pre-existing username this controller was seeded with.
    private let existingUsername: ParsedUsername?

    /// Injected dependencies.
    private let context: Context

    private let nicknameValidator: Usernames.NicknameValidator = .init(
        minCodepoints: Constants.minNicknameCodepointLength,
        maxCodepoints: Constants.maxNicknameCodepointLength
    )

    private lazy var apiManager: Usernames.API = {
        .init(networkManager: context.networkManager)
    }()

    init(existingUsername: ParsedUsername?, context: Context) {
        self.existingUsername = existingUsername
        self.context = context

        super.init()

        usernameTextField.delegate = self
        usernameTextField.addTarget(self, action: #selector(usernameTextFieldContentsDidChange), for: .editingChanged)

        shouldAvoidKeyboard = true
    }

    /// Whether the user has edited the username to a value other than what we
    /// started with.
    var hasUnsavedEdits: Bool {
        if case .noChangesToExisting = currentUsernameState {
            return false
        }

        return true
    }

    // MARK: Views

    /// Navbar button for finishing this view.
    private lazy var doneBarButtonItem: UIBarButtonItem = {
        UIBarButtonItem(
            title: CommonStrings.doneButton,
            style: .done,
            target: self,
            action: #selector(didTapDone),
            accessibilityIdentifier: "done_button"
        )
    }()

    private lazy var headerView: HeaderView = {
        .init(withIconSize: Constants.headerViewIconSize)
    }()

    /// Manages editing of the nickname and presents additional visual state
    /// such as the current discriminator.
    private lazy var usernameTextField: UsernameTextField = {
        .init(forUsername: existingUsername)
    }()

    /// An ``NSAttributedString`` containing styled text to use as the footer
    /// for the username text field. Dynamically assembled as appropriate for
    /// the current internal state.
    private var usernameFooterStyled: NSAttributedString {
        var components = [Composable]()

        let errorText: String? = {
            switch currentUsernameState {
            case
                    .noChangesToExisting,
                    .shouldDelete,
                    .reservationPending,
                    .reservationSuccessful:
                return nil
            case .reservationRejected:
                return OWSLocalizedString(
                    "USERNAME_SELECTION_NOT_AVAILABLE_ERROR_MESSAGE",
                    comment: "An error message shown when the user wants to set their username to an unavailable value."
                )
            case .reservationFailed:
                return CommonStrings.somethingWentWrongTryAgainLaterError
            case .tooShort:
                return OWSLocalizedString(
                    "USERNAME_SELECTION_TOO_SHORT_ERROR_MESSAGE",
                    comment: "An error message shown when the user has typed a username that is below the minimum character limit. Embeds {{ %1$@ the minimum character count }}."
                )
            case .tooLong:
                owsFail("This should be impossible from the UI, as we limit the text field length.")
            case .invalidCharacters:
                return OWSLocalizedString(
                    "USERNAME_SELECTION_INVALID_CHARACTERS_ERROR_MESSAGE",
                    comment: "An error message shown when the user has typed a username that has invalid characters. The character ranges \"a-z\", \"0-9\", \"_\" should not be translated, as they are literal."
                )
            }
        }()

        if let errorText {
            components.append(errorText.styled(with: .color(.ows_accentRed)))
            components.append("\n\n")
        }

        // TODO: [Usernames] Add "learn more" link.
        components.append(OWSLocalizedString(
            "USERNAME_SELECTION_EXPLANATION_FOOTER",
            comment: "Footer text below a text field in which users type their desired username, which explains how usernames work."
        ))

        return NSAttributedString
            .composed(of: components)
            .styled(
                with: .font(.ows_dynamicTypeCaption1Clamped),
                .color(Theme.secondaryTextAndIconColor)
            )
    }

    // MARK: View lifecycle

    override func themeDidChange() {
        super.themeDidChange()

        updateTableContents()
        updateNavigation()
    }

    /// Only allow gesture-based dismissal when there have been no edits.
    override var isModalInPresentation: Bool {
        get { hasUnsavedEdits }
        set {}
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString(
            "USERNAME_SELECTION_TITLE",
            comment: "The title for the username selection view."
        )

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(didTapCancel),
            accessibilityIdentifier: "cancel_button"
        )

        navigationItem.rightBarButtonItem = doneBarButtonItem

        updateTableContents()
        updateNavigation()
    }

    override func viewWillAppear(_ animated: Bool) {
        usernameTextField.becomeFirstResponder()
    }
}

// MARK: - Configure views

private extension UsernameSelectionViewController {
    /// Update the table contents to reflect the current internal state.
    private func updateTableContents() {
        let contents = OWSTableContents()

        // Holds a header image, and text displaying the entered username with
        // its discriminator.
        let headerSection: OWSTableSection = {
            let section = OWSTableSection()

            section.add(.init(
                customCellBlock: { [weak self] in
                    guard let self else { return UITableViewCell() }
                    let cell = OWSTableItem.newCell()

                    cell.selectionStyle = .none
                    cell.addSubview(self.headerView)
                    self.headerView.autoPinEdgesToSuperviewMargins()

                    self.headerView.setColorsForCurrentTheme()
                    self.headerView.updateFontsForCurrentPreferredContentSize()

                    // If we are able to finalize a username (i.e., have a
                    // reservation or deletion primed), we should display it.
                    let usernameDisplayText: String? = {
                        switch self.currentUsernameState {
                        case .noChangesToExisting:
                            if let existingUsername = self.existingUsername {
                                return existingUsername.reassembled
                            }

                            fallthrough
                        case .shouldDelete:
                            return OWSLocalizedString(
                                "USERNAME_SELECTION_HEADER_TEXT_FOR_PLACEHOLDER",
                                comment: "When the user has entered text into a text field for setting their username, a header displays the username text. This string is shown in the header when the text field is empty."
                            )
                        case let .reservationSuccessful(reservation):
                            return reservation.username.reassembled
                        case
                                .reservationPending,
                                .reservationRejected,
                                .reservationFailed,
                                .tooShort,
                                .tooLong,
                                .invalidCharacters:
                            return nil
                        }
                    }()

                    if let usernameDisplayText {
                        self.headerView.setUsernameText(to: usernameDisplayText)
                    }

                    return cell
                },
                actionBlock: nil
            ))

            section.hasBackground = false

            return section
        }()

        // Holds the text field for entering the username, as well as
        // descriptive text underneath.
        let usernameTextFieldSection: OWSTableSection = {
            let section = OWSTableSection()

            section.add(.init(
                customCellBlock: { [weak self] in
                    guard let self else { return UITableViewCell() }
                    let cell = OWSTableItem.newCell()

                    cell.selectionStyle = .none
                    cell.addSubview(self.usernameTextField)
                    self.usernameTextField.autoPinEdgesToSuperviewMargins()

                    self.usernameTextField.setColorsForCurrentTheme()
                    self.usernameTextField.updateFontsForCurrentPreferredContentSize()

                    switch self.currentUsernameState {
                    case .noChangesToExisting:
                        self.usernameTextField.configure(forConfirmedUsername: self.existingUsername)
                    case .shouldDelete:
                        self.usernameTextField.configure(forConfirmedUsername: nil)
                    case .reservationPending:
                        self.usernameTextField.configureForReservationInProgress()
                    case let .reservationSuccessful(reservation):
                        self.usernameTextField.configure(forConfirmedUsername: reservation.username)
                    case
                            .reservationRejected,
                            .reservationFailed,
                            .tooShort,
                            .tooLong,
                            .invalidCharacters:
                        self.usernameTextField.configureForError()
                    }

                    return cell
                },
                actionBlock: nil
            ))

            section.footerAttributedTitle = usernameFooterStyled

            return section
        }()

        contents.addSections([
            headerSection,
            usernameTextFieldSection
        ])

        let usernameTextFieldIsFirstResponder = usernameTextField.isFirstResponder

        self.contents = contents

        if usernameTextFieldIsFirstResponder {
            // By setting contents, we will steal first responder. We should
            // give it back.
            usernameTextField.becomeFirstResponder()
        }
    }

    /// Update the nav bar items to reflect the current internal state.
    private func updateNavigation() {
        doneBarButtonItem.isEnabled = {
            switch currentUsernameState {
            case
                    .reservationSuccessful,
                    .shouldDelete:
                return true
            case
                    .noChangesToExisting,
                    .reservationPending,
                    .reservationRejected,
                    .reservationFailed,
                    .tooShort,
                    .tooLong,
                    .invalidCharacters:
                return false
            }
        }()
    }
}

// MARK: - Nav bar events

private extension UsernameSelectionViewController {
    /// Called when the user cancels editing. Dismisses the view, discarding
    /// unsaved changes.
    @objc
    private func didTapCancel() {
        guard hasUnsavedEdits else {
            dismiss(animated: true)
            return
        }

        OWSActionSheets.showPendingChangesActionSheet(discardAction: { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true)
        })
    }

    /// Called when the user taps "Done". Attempts to finalize the new chosen
    /// username.
    @objc
    private func didTapDone() {
        let usernameState = self.currentUsernameState

        switch usernameState {
        case let .reservationSuccessful(reservation):
            self.confirmReservationBehindModalActivityIndicator(
                reservation: reservation
            )
        case .shouldDelete:
            self.deleteCurrentUsernameBehindActivityIndicator()
        case
                .noChangesToExisting,
                .reservationPending,
                .reservationRejected,
                .reservationFailed,
                .tooShort,
                .tooLong,
                .invalidCharacters:
            owsFail("Unexpected username state: \(usernameState). Should be impossible from the UI!")
        }
    }

    /// Confirm the given reservation, with an activity indicator blocking the
    /// UI.
    private func confirmReservationBehindModalActivityIndicator(
        reservation: API.SuccessfulReservation
    ) {
        ModalActivityIndicatorViewController.present(
            fromViewController: self,
            canCancel: false
        ) { modal in
            UsernameLogger.shared.info("Confirming username.")

            firstly { () -> Promise<API.ConfirmationResult> in
                self.apiManager.attemptToConfirm(reservation: reservation)
            }.done(on: .main) { result -> Void in
                switch result {
                case let .success(confirmedUsername):
                    UsernameLogger.shared.info("Confirmed username!")

                    self.persistNewUsernameValueAndDismiss(
                        usernameValue: confirmedUsername,
                        presentedModalActivityIndicator: modal
                    )
                case .rejected:
                    UsernameLogger.shared.error("Failed to confirm the username, server rejected.")

                    self.dismiss(
                        modalActivityIndicator: modal,
                        andPresentErrorMessage: CommonStrings.somethingWentWrongError
                    )
                case .rateLimited:
                    UsernameLogger.shared.error("Failed to confirm the username, rate-limited.")

                    self.dismiss(
                        modalActivityIndicator: modal,
                        andPresentErrorMessage: CommonStrings.somethingWentWrongTryAgainLaterError
                    )
                }
            }.catch(on: .main) { error in
                UsernameLogger.shared.error("Error while confirming username: \(error)")

                self.dismiss(
                    modalActivityIndicator: modal,
                    andPresentErrorMessage: CommonStrings.somethingWentWrongTryAgainLaterError
                )
            }
        }
    }

    /// Delete the user's existing username, with an activity indicator
    /// blocking the UI. Prompts the user first to confirm deletion.
    private func deleteCurrentUsernameBehindActivityIndicator() {
        let confirmDeletionActionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "USERNAME_SELECTION_DELETION_CONFIRMATION_ALERT_TITLE",
                comment: "A message asking the user if they are sure they want to remove their username."
            )
        )

        let confirmAction = ActionSheetAction(
            title: OWSLocalizedString(
                "USERNAME_SELECTION_DELETE_USERNAME_ACTION_TITLE",
                comment: "The title of an action sheet button that will delete a user's username."
            ),
            style: .destructive
        ) { _ in
            ModalActivityIndicatorViewController.present(
                fromViewController: self,
                canCancel: false
            ) { modal in
                UsernameLogger.shared.warn("Deleting existing username.")

                firstly {
                    self.apiManager.attemptToDeleteCurrentUsername()
                }.map(on: .main) {
                    UsernameLogger.shared.info("Username deleted!")

                    self.persistNewUsernameValueAndDismiss(
                        usernameValue: nil,
                        presentedModalActivityIndicator: modal
                    )
                }.catch(on: .main) { error in
                    UsernameLogger.shared.error("Error while deleting username: \(error)")

                    self.dismiss(
                        modalActivityIndicator: modal,
                        andPresentErrorMessage: CommonStrings.somethingWentWrongTryAgainLaterError
                    )
                }
            }
        }

        confirmDeletionActionSheet.addAction(confirmAction)
        presentActionSheet(confirmDeletionActionSheet)
    }

    /// Persist the given username value, dismiss the given activity indicator,
    /// then dismiss the current view.
    /// - Parameter usernameValue
    /// A new username value. `nil` if the username was deleted.
    /// - Parameter presentedModalActivityIndicator
    /// A currently-presented modal activity indicator to be dismissed.
    private func persistNewUsernameValueAndDismiss(
        usernameValue: String?,
        presentedModalActivityIndicator modal: ModalActivityIndicatorViewController
    ) {
        self.context.databaseStorage.write { transaction in
            self.context.profileManager.updateLocalUsername(
                usernameValue,
                userProfileWriter: .localUser,
                transaction: transaction
            )
        }

        modal.dismiss(animated: false) {
            self.dismiss(animated: true)
        }
    }

    /// Dismiss the given activity indicator and then present an error message
    /// action sheet.
    private func dismiss(
        modalActivityIndicator modal: ModalActivityIndicatorViewController,
        andPresentErrorMessage errorMessage: String
    ) {
        modal.dismiss(animated: false) {
            OWSActionSheets.showErrorAlert(message: errorMessage)
        }
    }
}

// MARK: - Text field events

private extension UsernameSelectionViewController {
    /// Called when the contents of the username text field have changed, and
    /// sets local state as appropriate. If the username is believed to be
    /// valid, kicks off a reservation attempt.
    @objc
    private func usernameTextFieldContentsDidChange() {
        AssertIsOnMainThread()

        UsernameLogger.shared.debug("Username text field contents changed...")

        let nicknameFromTextField: String? = usernameTextField.normalizedNickname

        if existingUsername?.nickname == nicknameFromTextField {
            currentUsernameState = .noChangesToExisting
        } else if let desiredNickname = nicknameFromTextField {
            // We have an entered nickname
            switch nicknameValidator.validate(desiredNickname: desiredNickname) {
            case .success:
                attemptReservationAndUpdateValidationState(
                    forDesiredNickname: desiredNickname
                )
            case .invalidCharacters:
                currentUsernameState = .invalidCharacters
            case .tooLong:
                currentUsernameState = .tooLong
            case .tooShort:
                currentUsernameState = .tooShort
            }
        } else {
            // We have an existing username, but no entered nickname.
            currentUsernameState = .shouldDelete
        }
    }

    /// Attempts to reserve the given nickname, and updates ``validationState``
    /// as appropriate.
    ///
    /// The desired nickname might change while prior reservation attempts are
    /// in-flight. In order to disambiguate between reservation attempts, we
    /// track an "attempt ID" that represents the current reservation attempt.
    /// If a reservation completes successfully but the current attempt ID does
    /// not match the ID with which the reservation was initiated, we discard
    /// the result (as we have moved on to another desired nickname).
    private func attemptReservationAndUpdateValidationState(
        forDesiredNickname desiredNickname: String
    ) {
        AssertIsOnMainThread()

        struct ReservationNotAttemptedError: Error {
            let attemptId: UUID
        }

        firstly { () -> Guarantee<UUID> in
            let attemptId = UUID()

            currentUsernameState = .reservationPending(attemptId: attemptId)

            // Delay to detect multiple rapid consecutive edits.
            return Guarantee
                .after(wallInterval: Constants.reservationDebounceTimeInternal)
                .map(on: .main) { attemptId }
        }.then(on: .main) { thisAttemptId throws -> Promise<API.ReservationResult> in
            // If this attempt is no longer current after debounce, we should
            // bail out without firing a reservation.
            guard
                case let .reservationPending(currentAttemptId) = self.currentUsernameState,
                thisAttemptId == currentAttemptId
            else {
                UsernameLogger.shared.debug("Not attempting to reserve, attempt is outdated. Attempt ID: \(thisAttemptId)")
                throw ReservationNotAttemptedError(attemptId: thisAttemptId)
            }

            UsernameLogger.shared.info("Attempting to reserve username. Attempt ID: \(thisAttemptId)")

            return self.apiManager.attemptToReserve(
                desiredNickname: desiredNickname,
                attemptId: thisAttemptId
            )
        }.done(on: .main) { [weak self] reservationResult -> Void in
            guard let self else { return }

            // If the reservation we just attempted is not current, we should
            // drop it and bail out.
            guard
                case let .reservationPending(attemptId) = self.currentUsernameState,
                reservationResult.attemptId == attemptId
            else {
                UsernameLogger.shared.info("Dropping reservation result, attempt is outdated. Attempt ID: \(reservationResult.attemptId)")
                return
            }

            switch reservationResult.state {
            case let .successful(reservation):
                UsernameLogger.shared.info("Successfully reserved nickname! Attempt ID: \(attemptId)")

                self.currentUsernameState = .reservationSuccessful(reservation: reservation)
            case .rejected:
                UsernameLogger.shared.warn("Reservation rejected. Attempt ID: \(attemptId)")

                self.currentUsernameState = .reservationRejected
            case .rateLimited:
                UsernameLogger.shared.error("Reservation rate-limited. Attempt ID: \(attemptId)")

                // Hides the rate-limited error, but not incorrect.
                self.currentUsernameState = .reservationFailed
            }
        }.catch(on: .main) { [weak self] error in
            guard let self else { return }

            if let error = error as? ReservationNotAttemptedError {
                UsernameLogger.shared.debug("Reservation was not attempted. Attempt ID: \(error.attemptId)")
                return
            }

            self.currentUsernameState = .reservationFailed

            if let error = error as? API.ReservationError {
                UsernameLogger.shared.error("Reservation failed with error \(error.underlying). Attempt ID: \(error.attemptId)")
            } else {
                owsFailDebug("Reservation failed with unexpected error \(error)!")
            }
        }
    }
}

// MARK: - UITextFieldDelegate

extension UsernameSelectionViewController: UITextFieldDelegate {
    /// Called when user action would result in changed contents in the text
    /// field.
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        return TextFieldHelper.textField(
            textField,
            shouldChangeCharactersInRange: range,
            replacementString: string,
            maxUnicodeScalarCount: Int(Constants.maxNicknameCodepointLength)
        )
    }
}
